# AD5560 FPGA 系统架构

## 1. 系统

本系统由一片 FPGA 控制 **128 颗 AD5560**。上位机负责下发配置表和运行命令，FPGA 负责配置执行、上下电时序、Alarm 处理、系统 fault 处理以及 AD5560 寄存器访问。

### 1.1 SPI 与控制信号

- 共 **8 组 SPI 总线**；
- 每组 SPI 连接 16 颗 AD5560；
- `SYNC` 每颗 AD5560 独立，共 **128 路**；
- 每条 BUS 对应 1 路共享 `BUSY`；
- 每条 BUS 对应 1 路 `ALARM`；
- 每条 BUS 对应一个 `AD5560 Driver` 和一个通用 `SPI Master`。

`AD5560 Driver` 负责本 BUS 的寄存器事务、16 路 `SYNC` 选择、`BUSY` timeout 和本 BUS sticky `bus_fault`。

### 1.2 HW_INH

系统当前只使用 **1 根全局 `HW_INH`**。

正常上下电主要采用 AD5560 的 **Ramp Function + SPI 软件控制**，`HW_INH` 不作为正常单通道上下电时序控制信号。



---


## 2. Driver BUS 选择

System Controller 只根据系统状态产生 `sel_id`，用于选择当前业务模块。

当前业务模块输出统一命令字段：

```text
cmd_valid
cmd_bus_id
cmd_device_id
cmd_reg_addr
cmd_wr_data
```

顶层对 8 个 Driver 循环例化，并在每个实例中用固定 `BUS_ID` 与 `cmd_bus_id` 比较：

```verilog
assign bus_selected = (cmd_bus_id == BUS_ID);
assign driver_cmd_valid = cmd_valid && bus_selected;
assign cmd_ready = driver_cmd_ready[cmd_bus_id];
```

因此 8 条 BUS 的目标选择由命令自身的 `BUS_ID` 和顶层 generate 路由完成，不由 System Controller 做 BUS 仲裁。


Driver 在 `valid && ready` 时锁存本次命令。对于写事务，业务模块握手后可继续处理后续独立命令；对于读事务，若后续流程依赖读回结果，则必须等待 `rsp_valid` 后再继续。

### 2.2 业务模块握手原则

Config Manager、Power Sequence Engine、Alarm Handler 等业务模块统一使用 `valid / ready` 完成命令提交。

```text
valid && ready = 1
```

表示当前命令已经被目标 Driver 接收。Driver 在握手后锁存命令参数并独立执行底层 SPI / BUSY 流程。

对于**写事务**：

- `valid / ready` 握手完成即表示该写命令已经提交；
- 业务模块不等待额外的 `ok / done`；
- 业务模块不判断 SPI / BUSY 是否执行成功；
- Driver 检测到 `BUSY timeout` 等异常后输出 `bus_fault`，由 System Controller 统一处理。

对于**读事务**：

- `valid / ready` 仅表示读命令已经提交给 Driver；
- Driver 内部完成 AD5560 两帧 readback 流程；
- 业务模块必须等待 `rsp_valid`，并在 `rsp_valid` 有效时取得 `rsp_rd_data`；
- 任何依赖读回数据的后续流程，只能在收到 `rsp_valid` 后继续。

因此：

```text
WRITE : valid/ready = 命令提交完成，业务模块可继续派发后续独立命令
READ  : valid/ready = 读命令提交完成，rsp_valid = 读结果返回完成
```

底层错误仍由 Driver 和 System Controller 统一处理，业务模块不重复实现底层错误判断。

---

## 3. 各模块连接关系

```mermaid
flowchart TB
    PC[上位机]
    COMM[通信 / 命令分发]

      SYS[System Controller\n系统状态 / sel_id / fault锁存]
      CM[Config Manager\n配置]
      PSE[Power Sequence Engine\n全局上下电时序]
      AH[Alarm Handler\n事件触发读取状态]
      
      subgraph DRIVERS[AD5560 Driver x8]
      DRV[BUS0 ~ BUS7 Driver\nvalid/ready + SYNC + BUSY + bus_fault]
      SPI[SPI Master x8\n通用 SPI]
      DRV --> SPI
      end
      
      SYS --> CM
      SYS --> AH
      SYS --> PSE
 

      MUX[业务命令 MUX\nsel_id 选择命令源]
      ROUTE[BUS 路由\ncmd_bus_id == BUS_ID]

      CM --> MUX
      PSE --> MUX
      AH --> MUX
      MUX --> ROUTE
      ROUTE --> DRV

    DEV[128 × AD5560\n8 BUS × 16 Device]

    PC --> COMM
    COMM -->|写ram| CM
    COMM -->|写命令| SYS
    COMM -->|写ram| PSE

    SPI --> DEV
    DRV -->|SYNC 128 路| DEV
    DEV -->|BUSY 8 路| DRV
```
