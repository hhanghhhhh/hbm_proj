# AD5560 Config Manager 设计

## 1. 模块定位

`Config Manager` 负责执行 AD5560 的初始化配置表。

其职责仅限于：

- 接收通信侧写入的配置记录；
- 保存配置记录；
- 配置启动后按顺序读取记录；
- 将每条记录转换成一笔 AD5560 寄存器写事务；
- 当前记录完成 `valid / ready` 握手后立即继续下一条；
- 检测 `Command Arbiter` 输出的总 `bus_fault`，出现故障后停止剩余配置。

`Config Manager` 不负责上下电时序、Alarm 处理或其他运行期寄存器控制。

后续 FPGA 内部如需运行期读写 AD5560 寄存器，应由独立功能模块通过 `Command Arbiter` 直接访问对应 `AD5560 Driver`，不经过 `Config Manager`。

---

## 2. Config RAM

第一版将 **Config RAM 直接放在 `Config Manager` 内部**。

```text
Config Manager
├─ Config RAM
│   ├─ 写口：通信侧写入配置记录
│   └─ 读口：Config Manager 顺序读取
│
└─ Config FSM
```

Config RAM 采用单块全局 RAM，不按 8 条 SPI BUS 分开。

通信侧先完成配置表写入，再启动配置。配置执行期间不允许修改当前 Config RAM。

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

## 3. 通信侧接口

```text
cfg_ram_wr_en
cfg_ram_wr_addr
cfg_ram_wr_data[31:0]

cfg_start
cfg_record_count

cfg_busy
cfg_done
cfg_error
```

其中：

- `cfg_start` 为单 clk 启动脉冲；
- `cfg_record_count` 表示本次有效记录数量；
- `cfg_busy` 表示正在派发配置记录；
- `cfg_done` 表示全部配置记录已经完成握手并提交给下游；
- `cfg_error` 表示配置过程中检测到 `bus_fault`，剩余记录停止派发。

SPI 写本身没有 ACK，因此 Config Manager 不等待逐条写事务完成，也不维护逐条配置结果。

---

## 4. 配置执行流程

Config Manager 按 Config RAM 顺序产生单路命令流：

```text
IDLE
  ↓
cfg_start
  ↓
index = 0
  ↓
读取 Config RAM[index]
  ↓
解析 BUS_ID / DEVICE_ID / REG_ADDR / REG_DATA
  ↓
向 Command Arbiter 提交寄存器写事务
  ↓
等待 cfg_cmd_valid && cfg_cmd_ready
  ↓
握手完成：index + 1，立即处理下一条
  ↓
全部记录完成握手后 cfg_done
```

目标 Driver 忙时，其 `ready` 通过 `Command Arbiter` 返回为低，Config Manager 保持当前记录不变并等待。

因此配置记录仍按 RAM 顺序派发，但不同 BUS 的实际 SPI 事务可以重叠执行：

```text
BUS0 record → handshake
BUS3 record → handshake
BUS7 record → handshake
BUS0 record → 若 BUS0 Driver 仍忙，则停在该记录等待
```

第一版不做乱序调度或跳过当前记录。

---

## 5. bus_fault 处理

Config Manager 只接收 `Command Arbiter` 汇总后的单 bit：

```text
bus_fault
```

配置期间只要检测到：

```text
bus_fault = 1
```

则：

```text
停止继续读取 / 派发剩余 Config RAM 记录
cfg_busy  = 0
cfg_error = 1
```

已经完成握手并交给其他 Driver 的事务不取消，由对应 Driver 自行结束。

具体是哪条 BUS 故障由 `Command Arbiter` 的 `bus_fault_vector[7:0]` 提供给其他状态 / 故障管理模块；Config Manager 自身不需要该向量。

---

## 6. 与 Command Arbiter 的接口

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

---

## 7. 模块连接关系

```text
Config Manager
      │
      ▼
Command Arbiter
      │
      ▼
AD5560 Driver × 8
      │
      ▼
SPI Master × 8
```

`Power Sequence Engine`、`Alarm Handler` 和后续可能增加的运行期控制模块也作为独立命令源接入同一个 `Command Arbiter`。