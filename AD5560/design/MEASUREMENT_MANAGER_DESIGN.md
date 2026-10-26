# Measurement Manager 设计

## 1. 定位与总体方案

`Measurement Manager` 负责 128 路 AD5560 的电压/电流（V/I）交替测量调度、采样数据归属及 Result RAM 更新。它不实现 AD4114/AD5560 底层 SPI，也不独占 System Controller 的主业务状态机。

- `ad4114_sample_manager`：负责 ADC 初始化、连续轮询、错误过滤，输出 `sample_valid + adc_id + adc_channel + sample_data[23:0]`。
- `Measurement Manager`：根据采样来源定位 AD5560 通道；保存数据到 V/I RAM；生成下一次 MEASOUT 切换请求；管理启停/暂停。
- `AD5560 Driver ×8`：执行 AD5560 寄存器写及 BUSY 超时检测，复用现有 `valid/ready` 命令接口。
- **寄存器 Shadow RAM 是独立外部模块，不放在 Measurement Manager 内部**；Manager 通过读写接口访问。
- 上位机通过 `TELEMETRY_ENABLE` 选择参与测量的通道，通过 `TELEMETRY_READ` 按需读取最新缓存；读取不触发采样。

核心简化：**每通道只维护一个 V/I 状态位和一个待切换位，不实例化 128 个状态机**；全局只有一套调度 FSM。

## 2. 硬件关系和通道映射

一片 FPGA 控制 8 条 AD5560 SPI BUS，每 BUS 16 颗 AD5560。对应 16 颗 AD4114（每 BUS 两颗 ADC，每颗 8 路差分）。AD4114 共用其自身一组 SPI，由 `ad4114_sample_manager` 顺序读取，故对外每拍最多产生一个 `sample_valid`，即使多颗 ADC 同时 RDY 也不会同拍输出多点。

在 ADC 编号与 BUS 绑定为连续编号的接线假设下：

```text
bus_id    = adc_id >> 1                // ADC0/1 -> BUS0，ADC2/3 -> BUS1 ...
device_id = {adc_id[0], adc_channel}  // 每片 ADC 对应本 BUS 的 8 颗 Device
channel   = {bus_id[2:0], device_id[3:0]}  // 0~127
```

此映射必须与实际 PCB 连线核对；若接线不同，修改映射逻辑，不影响其余调度架构。

AD4114 配置为连续转换（当前 Filter0 = `0x0510`，约 20.13 ms/通道，8 路约 161 ms/轮）。ADC 启动后持续采样，不随上位机测量 Mask 重新初始化；建议 `i_skip_cnt=0`，V/I 数据是否可用由本模块判断。

## 3. 内部状态与存储

| 资源 | 规模 | 作用 |
|---|---:|---|
| `enable_mask` | 128 bit | 上位机使能测量的通道 |
| `vi_state` | 128 bit | 该通道**已确认切换完成**的模式；0=V，1=I |
| `switch_pending` | 128 bit | 收到采样后，等待切换到相反 V/I 模式的通道 |
| 切换调度 FSM | 1 套 | 选取 pending 通道、读 Shadow、修改位域、发 AD5560 写命令、等待完成 |
| Voltage Result RAM | 128 × 24 bit | 各通道最近一次有效电压 ADC Raw |
| Current Result RAM | 128 × 24 bit | 各通道最近一次有效电流 ADC Raw |

V/I Result RAM 可分别实例化为独立存储块。总容量 `128×24×2 = 6144 bit = 768 Byte`。结果数据只有 24-bit 原码，不额外向上位机返回 FLAG。

**外部 Shadow RAM**：独立维护每颗 AD5560 的 `0x01` 和 `0x02` 当前寄存器值；逻辑容量建议 `128 × 32 bit = 4096 bit`，具体模块接口和初值来源后续确定。

## 4. 接收 ADC 数据：直接写 RAM，异步排队切换

收到 `sample_valid` 后：

1. 用 `adc_id + adc_channel` 算出全局 `channel`。
2. 若通道未使能，或已暂停到无法确认当前模式，忽略该点。
3. 若 `switch_pending[channel]=1`（上一次模式切换尚未完成），**本点丢弃，不按旧模式重复写 RAM，也不重复生成切换任务**。
4. 否则按 `vi_state[channel]` 写 `Voltage/Current Result RAM[channel]`，同时令 `switch_pending[channel]=1`，请求切换到相反模式。

ADC 数据与 Result RAM 写入在采样接收侧完成；**不需要为 ADC 数据做大 FIFO**。切换命令通过 `switch_pending` 128-bit 位图缓存，即使连续多个 `sample_valid` 相隔很近，也不丢失各通道的切换请求。实现时需处理同周期 pending 置位/清除的优先级。

## 5. 切换调度器（单个 FSM）

```text
查找 switch_pending 中可处理的通道
      ↓
读外部 Shadow RAM：该 CH 的 0x01、0x02
      ↓
按目标 V/I 修改测量相关 bit，保留其它 bit
      ↓
必要时写 AD5560 0x01（MEASOUT Gain）
      ↓
写 AD5560 0x02（MEASOUT 选择）
      ↓
等待对应 Driver 的写事务真正结束
      ↓
同步外部 Shadow RAM 的寄存器当前值
      ↓
vi_state[CH] 翻转；switch_pending[CH] 清零
      ↓
继续查找下一个 pending
```

- `0x02` 只修改 MEASOUT 的 `ME[8:5]` 字段，不覆盖 SW_INH、量程、Clamp 等配置。
- `0x01` 是否每次都要写，取决于该 Device 的 V/I 测量增益是否不同；不变时可不写。
- `valid && ready` 只表示 Driver 接收了写事务，**不等于写完成**；切换状态应在最后一笔写执行完成、目标 Driver 恢复 ready 且未发生 bus_fault 后更新。
- 某 BUS 正在执行 SPI 写时，调度器可继续提交其它 BUS 的切换；8 个 Driver 彼此独立。相同 BUS 内仍由 Driver 顺序执行。
- 若一次 V/I 切换需写 0x01 和 0x02，应作为同一个通道的完整切换任务，在两笔操作完成后才更新 `vi_state`。
- Shadow RAM 的并发访问/读改写一致性需由外部 Shadow 管理及命令仲裁保证，避免 Config/Sequence/Measurement 互相覆盖。

## 6. 数据有效性约定

第一版采用简化时序：**完成 AD5560 V/I 切换后，默认该通道下一次正常的 `sample_valid` 属于新模式**，不额外设固定延时，也不使用 AD4114 `skip_cnt` 过滤切换后的固定点数。

依据：同一 ADC 通道更新间隔约 161 ms，AD5560 SPI 写通常为微秒量级，正常情况下有较大时间余量。

例外保护：

- 当前通道的切换仍 pending/进行中时，ADC 点不入库。
- 如果 System 中途禁止 SPI、Driver 故障或模式无法确认，不得将该点作为已切换模式的数据保存。
- 这一简化依赖切换在下一次 ADC 有效转换窗口开始前完成且模拟输出稳定；若上板发现极端延迟或跨切换转换问题，再增加按时间/转换轮次丢点保护，不在第一版引入完整 ADC 转换时间追踪。

`vi_state` 表示已确认的实际配置状态，不在收到 `sample_valid` 或提交 SPI 命令时提前翻转。

## 7. System Controller 协作、暂停与恢复

Measurement 属于**低优先级后台业务**，不作为长期独占 `sel_id` 的 Config/Sequence/Alarm 主任务。现有高优先级业务优先使用 Driver；测量命令通过顶层仲裁入口复用现有 8 路 Driver。

### 7.1 正常运行

- AD4114 一直轮询，与 AD5560 业务是否占用 SPI 无关。
- 上位机先完成配置/上电，再下发 `TELEMETRY_ENABLE`；复位后测量 Mask 默认全 0。
- 在 System 允许测量时，启用通道持续按 `V → I → V` 交替切换。

### 7.2 正常暂停（如即将执行 Power Sequence）

1. System 发出“暂停测量切换/回到 V 模式”请求。
2. Manager 停止安排新的 V→I 请求；对当前在 I 模式的启用通道执行 I→V，等待已提交的测量写事务完成。
3. 所有目标通道确认处于 V、且 Manager 不再占用 AD5560 SPI 后，返回 `meas_paused` 给 System。
4. System 才开始后续需要独占/及时使用 SPI 的正常任务。暂停期间 AD4114 可继续运行，确认处于 V 模式的采样可继续刷新 Voltage RAM，不再发起 V/I 交替切换。
5. 恢复时从已确认的 V 状态重新开始测量。

**不能仅清零 `vi_state` 冒充硬件已经切回 V。**

### 7.3 紧急 Alarm / bus_fault

Alarm/Fault 需立即获得高优先级处理，**不能等待全部通道 I→V 回切完成**。Manager 立即停止提交新切换；对尚未完成的切换状态保持待确认/失效处理，不把不确定模式的 ADC 点写入 Result RAM。故障处理完毕且重新允许测量后，再执行模式恢复/重新建立 V 基线。

上电、配置或复位等流程若修改了测量相关寄存器，也必须重新同步实际 V/I 模式与 Shadow，不允许继续假定旧的 `vi_state` 必然有效。

> 正常暂停完成返回 `meas_paused`，与紧急故障打断并不等价；紧急打断后不承诺所有器件已回到 V。

## 8. 上位机协议与 Result RAM

沿用 `design/comm/CMD_DEFINITION.md` 已定义的遥测命令：

| CMD | 请求 | 响应 |
|---|---|---|
| `0x50 TELEMETRY_ENABLE` | `ENABLE_MASK(16)` | `STATUS(1)` |
| `0x51 TELEMETRY_READ` | `READ_MASK(16)` | `STATUS(1) + DATA(6×N)` |

- 128-bit Mask 为大端，bit n 对应全局 CHn。
- `ENABLE_MASK` 控制后台采样参与通道，独立于 AD4114 初始化使能 Mask；全 0 表示不再进行测量模式切换。
- `TELEMETRY_READ` 只取 Result RAM 最近缓存，不触发采样、切换或等待下一轮 ADC。
- 按选中通道号升序返回，单通道 `VOLTAGE_RAW(3) + CURRENT_RAW(3)`，均为原始 24-bit、大端。全 128 路返回 `1+128×6=769 Byte`，满足当前 1024 Byte Payload 上限。
- 只在本次采样有效且模式确认时写 Result RAM；**协议不带有效 FLAG**。启用后第一次 V/I 都写入之前、或禁用后再读取，仍可能读到初值或旧缓存；上位机负责选择适当的首次读取时间。

## 9. 待下一步确定

1. 外部 Shadow RAM 的初值如何建立；Config/Sequence 写 `0x01 / 0x02` 时如何统一更新；是否单独保存各 Device 的 V/I Gain 配置。
2. 顶层测量命令仲裁具体接口，以及 `meas_pause / meas_paused` 的时序。
3. 由外部 Shadow 模块提供 RAM 读/写握手和互斥机制的具体定义。
4. 上板验证 V/I 切换相对 ADC 转换窗口的裕量、暂停/故障后的重新同步，以及测量数据的实际刷新周期。

本文件只记录架构讨论，尚未实现 Measurement Manager RTL，也不修改现有 AD4114 采样模块。
