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

其中：

- `cfg_start` 为单 clk 启动脉冲；
- `cfg_abort` 为系统故障或其他上层原因导致的终止信号；
- `cfg_busy` 表示正在派发配置记录；
- `cfg_done` 表示全部配置记录已经完成握手并提交给下游；
- `cfg_error` 表示本次配置被 `cfg_abort` 终止。

SPI 写本身没有 ACK，因此 Config Manager 不等待逐条写事务完成，也不维护逐条配置结果。

---

## 4. 配置执行流程

Config Manager 按 Config RAM 顺序产生单路命令流。

配置记录仍按 RAM 顺序派发，但不同 BUS 的实际 SPI 事务可以重叠执行。

第一版不做乱序调度或跳过当前记录。

---

## 5. abort 处理

系统 fault 由 `System Controller` 统一判断。发生系统 fault 时 Config Manager 停止继续派发。

已经完成握手并交给 Driver 的事务不取消，由对应 Driver 自行结束。

---

## 6. 与 System Controller 的命令接口

Config Manager 作为一个写命令源输出：

```text
cfg_cmd_valid
cfg_cmd_ready
cfg_bus_id[2:0]
cfg_device_id[3:0]
cfg_reg_addr[6:0]
cfg_wr_data[15:0]
```

由于 Config Table 第一版只有写操作，统一命令接口中的 `RW` 固定为写。

```text
cfg_cmd_valid && cfg_cmd_ready
```

表示当前配置记录已经被目标 Driver 接收。握手后 Config Manager 直接处理下一条记录。

AD5560 Driver × 8
```

`Power Sequence Engine`、`Alarm Handler` 和后续可能增加的运行期控制模块也作为独立命令源接入 `System Controller`。
