# AD5560 Config Manager 设计

## 1. 模块定位

`Config Manager` 负责执行 AD5560 的初始化配置表。

职责：

- 接收通信侧写入的配置记录；
- 保存配置记录；
- 收到 `System Controller` 的 `cfg_start` 后按顺序读取记录；
- 将每条记录转换成一笔 AD5560 寄存器写事务；
- 当前记录完成 `valid / ready` 握手后立即继续下一条；
- 收到 `cfg_abort` 后停止当前配置流程。

---

## 2. Config RAM

第一版将 **Config RAM 直接放在 `Config Manager` 内部**。

Config RAM 采用单块全局 RAM，不按 8 条 SPI BUS 分开。

通信侧先完成配置表写入，再由 `System Controller` 启动配置。配置执行期间不允许修改当前 Config RAM。

### 2.1 配置记录

每条配置记录包含：

```text
BUS_ID      3 bit
DEVICE_ID   4 bit
REG_ADDR    7 bit
REG_DATA   16 bit
```

共 30 bit，可使用 32 bit RAM，剩余位保留。

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

- `cfg_start` 为单 clk 启动脉冲；
- 仅在 `cfg_busy=0` 时接受 `cfg_start`；
- `cfg_busy=1` 期间再次收到 `cfg_start` 时直接忽略，不重新启动、不重置当前进度，也不产生额外 `cfg_done/cfg_error`；
- `cfg_abort` 为系统故障或其他上层原因导致的终止信号；
- `cfg_busy` 表示配置流程尚未真正结束；
- 全部配置记录完成 `valid / ready` 握手后，Config Manager 不再派发新命令；
- 随后等待 `cfg_bus_ready == 8'hFF`，确认所有 Driver 均已完成最后一批 SPI / BUSY 流程并恢复可接收状态；
- 只有在上述条件满足后才产生 `cfg_done`；
- `cfg_error` 表示本次配置被 `cfg_abort` 终止。

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

Config Manager 按 Config RAM 顺序产生单路命令流。

配置记录仍按 RAM 顺序派发，但不同 BUS 的实际 SPI 事务可以重叠执行。

第一版不做乱序调度或跳过当前记录。

### 4.1 空配置表

如果接受 `cfg_start` 时：

```text
cfg_record_count == 0
```

则本轮没有任何配置记录需要执行，Config Manager 直接结束本轮流程。

空配置表不需要等待 `cfg_bus_ready == 8'hFF`，因为本轮配置没有向 Driver 提交任何事务。

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


