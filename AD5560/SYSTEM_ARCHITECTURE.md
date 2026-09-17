# AD5560 FPGA 系统架构

## 1. 系统

本系统由一片 FPGA 控制 **128 颗 AD5560**。上位机负责下发配置表和运行任务，FPGA 负责配置数据缓存、寄存器配置执行、上下电时序控制以及后台遥测。

### 1.1 SPI 与 SYNC

- 共 **8 组 SPI 总线**；
- 每组 SPI 连接 16 颗 AD5560；
- `SYNC` 每颗 AD5560 独立，共 **128 根 SYNC**；
- 每条 BUS 对应一组共享 `BUSY`；
- 每条 BUS 对应一个 `Bus Service` 和一个 `AD5560 Driver`；
- `AD5560 Driver` 负责本组寄存器事务、16 路 `SYNC` 选择和 1 路共享 `BUSY`。

### 1.2 HW_INH

系统当前只使用 **1 根全局 `HW_INH`**。

正常上下电主要采用 AD5560 的 **Ramp Function + SPI 软件控制**，`HW_INH` 不作为正常单通道上下电时序控制信号。

---

## 2. Config Manager

配置采用**寄存器级配置表**方式。

上位机直接生成并下发 AD5560 配置记录，每条记录包含：

```text
BUS_ID + DEVICE_ID + REG_ADDR + REG_DATA
```

FPGA 不负责把电压、限流、Ramp 等工程参数转换成 AD5560 寄存器值，只负责保存和执行配置表。

### 2.1 Config RAM 组织

第一版将 **单块全局 Config RAM 直接放在 `Config Manager` 内部**，不按 8 条 SPI BUS 分开。

```text
Config Manager
├─ Config RAM
│   ├─ 通信侧写口
│   └─ Manager 内部读口
└─ Config FSM
```

所有 BUS、所有器件的配置记录按上位机生成的顺序连续存储。

`Config Manager` 启动后顺序读取记录。当前记录与下游完成 `valid / ready` 握手后，即可继续处理下一条记录，不等待本次 SPI 事务真正执行完成。

不同 BUS 已经接受的配置事务可以并行执行；如果后续记录目标 BUS 尚未 ready，则 Config Manager 在该记录处等待。

`Config Manager` 只监测 `Command Arbiter` 输出的总 `bus_fault`。任意 BUS 出现故障后，停止继续派发剩余配置记录。

---

## 3. Command Arbiter

`Config Manager`、`Power Sequence Engine` 以及后续可能增加的运行期寄存器控制模块，统一作为**前台命令源**接入 `Command Arbiter`。

```text
Config Manager ───────┐
Power Sequence Engine ├─> Command Arbiter ─> Bus Service × 8
Runtime Control       ┘     （后续可增加）
```

`Command Arbiter` 是上层控制模块与 8 个 `Bus Service` 之间的统一前台控制边界，负责：

- 选择当前前台命令来源；
- 根据 `BUS_ID` 将寄存器事务送到目标 `Bus Service`；
- 将目标 `Bus Service` 的 `ready` 返回给当前命令源；
- 汇总 8 个 `Bus Service` 的故障状态。

8 路 Service fault 汇总后，Arbiter 同时输出：

```text
bus_fault             // 任意 BUS 故障
bus_fault_vector[7:0] // 各 BUS 独立故障状态
```

其中：

```verilog
assign bus_fault = |bus_fault_vector;
```

`Command Arbiter` 只负责 fault 汇总，不负责故障锁存；故障状态由对应 `Bus Service` 自己维护。

第一版不需要复杂公平仲裁、命令队列或乱序调度。

后台 Telemetry 不参与前台命令仲裁，仍由各 `Bus Service` 内部自行调度。

---

## 4. Bus Service

每条 SPI BUS 设置一个 `Bus Service`，负责该 BUS 的本地任务调度。

对上层控制模块而言，`Bus Service` 只通过 `Command Arbiter` 连接，不再由 `Config Manager`、`Power Sequence Engine` 等模块分别直接连接。

主要职责：

- 接收 `Command Arbiter` 转发的前台寄存器事务；
- 在总线空闲时执行本 BUS 的后台遥测轮询；
- 调用本 BUS 的 `AD5560 Driver` 完成实际寄存器读写；
- 保存本 BUS 的最新遥测结果；
- 维护本 BUS 的故障状态并输出给 `Command Arbiter`。

本 BUS 内的优先级固定为：

```text
前台寄存器事务 > 后台 Telemetry
```

遥测功能按 BUS 独立运行，因此采用 **每 BUS 一块 Telemetry RAM**。

---

## 5. AD5560 Driver

`AD5560 Driver` 是单条 BUS 的 AD5560 寄存器事务执行层，只负责完成一笔指定器件的寄存器读写，不负责配置表管理、上下电时序调度或遥测轮询。

每个 Driver 负责：

- 根据 `DEVICE_ID` 将通用 SPI Master 的 `CS_n` 映射到本组 16 路独立 `SYNC` 中的一路；
- 组织 AD5560 寄存器读写所需 SPI 帧；
- 封装 AD5560 readback 两帧流程；
- 调用通用 `SPI Master`；
- 对写事务检测本组共享 `BUSY` 并处理 timeout。

Driver 检测到 `BUSY timeout` 后通知本 `Bus Service`，由 Service 锁存本 BUS 的 fault 状态。

---

## 6. 上下电时序组织

上下电时序采用 **单块全局 `Power Sequence RAM` + 单个 `Power Sequence Engine`**。

128 路上下电时序属于同一个全局时间轴，不按 BUS 分成 8 套独立时序。

`Power Sequence Engine` 顺序读取时序记录，产生统一的：

```text
BUS_ID + Register Transaction
```

事务先进入 `Command Arbiter`，再送到目标 `Bus Service`。

当前记录完成 `valid / ready` 握手后，`Power Sequence Engine` 即可继续读取下一条记录，不需要等待该 BUS 的实际寄存器事务完成。

因此：

```text
不同 BUS：事务可以重叠执行
同一 BUS：由本 BUS Service / Driver 自动串行执行
```

不同 BUS 的启动时间可能相差少量 FPGA clk，但不要求严格同一时钟周期启动。

系统级故障策略可直接使用 `Command Arbiter` 提供的 `bus_fault`；需要定位具体 BUS 时使用 `bus_fault_vector[7:0]`。

---

## 7. 多 BUS 选择

`Command Arbiter` 输出单路前台事务和 `BUS_ID`。

8 个 `Bus Service` 通过固定 `BUS_ID` 选择目标 Service：

```verilog
assign service_cmd_valid[n] = cmd_valid && (cmd_bus_id == n);
assign cmd_ready = service_cmd_ready[cmd_bus_id];
```

因此同一条前台命令只送到一个目标 `Bus Service`，而不同 BUS 已经接受的事务可以在各自 Service / Driver 中并行执行。

---

## 8. 各模块连接关系

```mermaid
flowchart TB
    PC[上位机]
    COMM[通信 / 命令分发]

    subgraph CTRL[ad5560_controller]
        subgraph CFG[Config Manager]
            CRAM[Config RAM\n全部 BUS 配置记录]
            CM[Config FSM\n握手后继续下一条]
            CRAM --> CM
        end

        PSRAM[Power Sequence RAM\n全局上下电时序]
        PSE[Power Sequence Engine\n产生运行事务]
        RC[Runtime Control\n后续按需增加]

        ARB[Command Arbiter\n命令源选择 / BUS选择 / fault汇总]

        subgraph BUS[Bus Service x8]
            BS[BUS0 ~ BUS7 Service\n前台事务 + 后台遥测 + bus_fault]
            TRAM[Telemetry RAM\n最新遥测数据]
            DRV[AD5560 Driver\n寄存器事务 + DEVICE/SYNC + BUSY]
            SPI[SPI Master\n通用 SPI]

            BS --> DRV
            BS --> TRAM
            DRV --> SPI
        end

        PSRAM --> PSE

        CM -->|Config Transaction| ARB
        PSE -->|Sequence Transaction| ARB
        RC -.->|Runtime Transaction| ARB
        ARB -->|BUS_ID + Register Transaction| BS
        BS -->|bus_fault[7:0]| ARB
        ARB -->|bus_fault| CM
        ARB -->|bus_fault / bus_fault_vector| PSE
    end

    DEV[128 × AD5560\n8 BUS × 16 Device]

    PC --> COMM
    COMM --> CRAM
    COMM --> CM
    COMM --> PSRAM
    COMM --> PSE

    SPI --> DEV
    DRV -->|SYNC 128 路| DEV
    DEV -->|BUSY 8 路| DRV
```
