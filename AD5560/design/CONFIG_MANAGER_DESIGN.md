# AD5560 Config Manager 设计

## 1. 模块定位

`Config Manager` 负责执行 AD5560 的初始化配置表。

职责：

- 接收通信侧写入的配置记录；
- 保存配置记录；
- 接收通信模块发起的 CRC 检查请求，校验最终 Config RAM Image；
- CRC 完成后向通信模块返回 `cfg_crc_done + cfg_crc_ok`；
- 收到 `System Controller` 的 `cfg_start` 后，将已校验表中的记录转换成 AD5560 寄存器写事务；
- 当前记录完成 `valid / ready` 握手后立即继续下一条；
- 收到 `cfg_abort` 后停止当前配置流程。

---

## 2. Config RAM

第一版将 **Config RAM 直接放在 `Config Manager` 内部**。

Config RAM 采用单块全局 RAM，不按 8 条 SPI BUS 分开。

通信侧先完成配置表写入并发起 CRC 校验。只有 CRC 通过后，通信模块才向 `System Controller` 发配置启动请求。CRC 校验和配置执行期间均不允许修改当前 Config RAM。

### 2.1 配置记录

每条配置记录固定使用 32 bit：

```text
[31:30] Reserved
[29:27] BUS_ID
[26:23] DEVICE_ID
[22:16] REG_ADDR
[15:0]  REG_DATA
```

有效字段共 30 bit，高 2 bit 保留。

第一版 Config Table 只执行寄存器写操作，因此记录中不需要 `RW` 字段。

### 2.2 RAM 容量计算

每条 Config Record 使用 1 个 32-bit word，实际需要保存 1024 条配置记录，则所需容量为：

```text
1024 × 32 bit
```

后续如果 Config Record 格式或最大记录数发生变化，应同步重新计算本节 RAM 容量。

---

## 3. 控制接口

通信侧负责 Config RAM 写入：

```text
cfg_ram_wr_en
cfg_ram_wr_addr
cfg_ram_wr_data[31:0]
cfg_record_count
cfg_expected_crc[15:0]
cfg_crc_start

返回：
cfg_crc_done
cfg_crc_ok
```

`System Controller` 负责配置流程控制：

```text
cfg_start
cfg_abort
```

Config Manager 返回：

```text
cfg_busy
cfg_done
cfg_error
```

另外，顶层将 8 个 Driver 的 `cmd_ready` 状态汇总提供给 Config Manager：

```text
cfg_bus_ready[7:0]
```

其中：

- `cfg_crc_start` 为通信模块发出的 CRC 检查脉冲；
- `cfg_crc_done` 为 CRC 计算完成单 clk 脉冲；
- `cfg_crc_ok` 与 `cfg_crc_done` 同步表示本轮 CRC 是否匹配，并保持到下一次 `cfg_crc_start/reset`；
- CRC 结果仅供通信模块使用，System Controller 不感知 CRC 状态；
- `cfg_start` 为 System Controller 发出的配置执行脉冲；
- 仅在 `cfg_busy=0` 时接受 `cfg_start`；
- `cfg_busy=1` 期间再次收到 `cfg_start` 时直接忽略，不重新启动、不重置当前进度，也不产生额外 `cfg_done/cfg_error`；
- `cfg_abort` 为系统故障或其他上层原因导致的终止信号；
- `cfg_busy` 只表示真正的配置执行过程，不包含 CRC 检查阶段；
- 全部配置记录完成 `valid / ready` 握手后，Config Manager 不再派发新命令；
- 随后等待 `cfg_bus_ready == 8'hFF`，确认所有 Driver 均已完成最后一批 SPI / BUSY 流程并恢复可接收状态；
- 只有在上述条件满足后才产生 `cfg_done`；
- `cfg_error` 仅表示已经开始的配置执行被 `cfg_abort` 终止；CRC 长度/校验结果通过 `cfg_crc_done/cfg_crc_ok` 返回通信模块。

因此 `cfg_done` 的语义为：

```text
全部配置记录已提交
+
所有 Driver 已恢复 ready
=
本轮配置流程真正完成
```

SPI 写本身没有 ACK，因此 Config Manager 不等待每一条写事务逐条返回结果，也不维护逐条配置结果；仅在全部记录提交完成后增加一次全局完成屏障。

---

## 4. 配置执行流程

CRC 检查和配置执行分为两个阶段。

通信模块收到上位机 `CONFIG_START` 后先发起 CRC 检查：

```text
锁存 cfg_record_count / cfg_expected_crc
    ↓
顺序读取 RAM[0 : cfg_record_count-1]
    ↓
每个 32-bit word 按 [31:24] → [23:16] → [15:8] → [7:0]
送入 CRC-16/MODBUS
    ↓
CRC 计算完成
    ↓
cfg_crc_done = 1 pulse
cfg_crc_ok   = 比较结果
    ↓
通信模块判断 crc_ok
    ├─ 0 -> 返回上位机，不向 System Controller 发启动请求
    └─ 1 -> 向 System Controller 发 cfg_start_req
```

`cfg_record_count` 最大为 1024；超出 RAM 深度时直接产生 `cfg_crc_done`，同时 `cfg_crc_ok=0`。

CRC 只用于确认多帧写入后 FPGA 内最终 RAM Image 完整正确，不替代通信帧自身的 CRC。

System Controller 后续发出 `cfg_start` 后，Config Manager 使用 CRC 阶段已锁存的 `cfg_record_count`，按 Config RAM 顺序产生单路命令流。

配置记录仍按 RAM 顺序派发，但不同 BUS 的实际 SPI 事务可以重叠执行。

第一版不做乱序调度或跳过当前记录。

### 4.1 空配置表

如果 CRC 请求的 `cfg_record_count == 0`，空数据 CRC 结果为 `16'hFFFF`。通信模块确认 CRC 通过并随后启动配置后，Config Manager 直接产生 `cfg_done`，不访问 Driver，也不等待 `cfg_bus_ready`。

### 4.2 正常配置表

最后一条配置记录完成 `valid / ready` 握手后，不立即产生 `cfg_done`，而是进入完成等待阶段：

```text
最后一条 Record 完成握手
    ↓
停止派发新配置命令
    ↓
等待 cfg_bus_ready == 8'hFF
    ↓
cfg_done = 1 pulse
    ↓
cfg_busy = 0
```

这样可保证 System Controller 进入 `READY` 时，不存在尚未结束的配置 SPI / BUSY 事务。

---

## 5. abort 处理

`cfg_abort` 优先于正常完成条件。若 `cfg_abort` 与 `cfg_done` 条件同周期出现，本轮按 abort 处理，不产生 `cfg_done`。

收到 `cfg_abort` 后停止继续派发；已经完成握手并交给 Driver 的事务不取消，由对应 Driver 自行结束。


