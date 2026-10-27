# Measurement Manager 设计

## 1. 定位与总体方案

`Measurement Manager` 负责 128 路 AD5560 的电压/电流（V/I）交替测量调度、采样数据归属及 Result RAM 更新。它不实现 AD4114/AD5560 底层 SPI；获得System授权期间独占AD5560 Driver资源池，内部8BUS可并行。

- `ad4114_sample_manager`：负责 ADC 初始化、连续轮询、错误过滤，输出 `sample_valid + adc_id + adc_channel + sample_data[23:0]`。
- `Measurement Manager`：根据采样来源定位 AD5560 通道；保存数据到 V/I RAM；生成下一次 MEASOUT 切换请求；管理启停/暂停。
- `AD5560 Driver ×8`：执行 AD5560 寄存器写及 BUSY 超时检测，复用现有 `valid/ready` 命令接口。
- **不再使用外部 Shadow RAM**；Measurement Manager 通过 AD5560 Driver 对器件寄存器执行 READ → 修改相关位 → WRITE，保留其他配置位。
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
| 切换调度 FSM | 1 套 | 选取 pending 通道、读取 AD5560 寄存器、计算 Gain、读改写并等待完成 |
| Voltage Result RAM | 128 × 24 bit | 各通道最近一次有效电压 ADC Raw |
| Current Result RAM | 128 × 24 bit | 各通道最近一次有效电流 ADC Raw |

V/I Result RAM 可分别实例化为独立存储块。总容量 `128×24×2 = 6144 bit = 768 Byte`。结果数据只有 24-bit 原码，不额外向上位机返回 FLAG。

**不配置 Shadow RAM**。切换时直接通过 AD5560 Driver 读回 `0x08`、`0x01`、`0x02` 的当前寄存器内容，并执行读改写。FSM 只临时锁存当前正在处理通道的读回值，不需要保存 128 路寄存器镜像。

## 4. 接收 ADC 数据：直接写 RAM，异步排队切换

收到 `sample_valid` 后：

1. 用 `adc_id + adc_channel` 算出全局 `channel`。
2. 若通道未使能，或已暂停到无法确认当前模式，忽略该点。
3. 若 `switch_pending[channel]=1`（上一次模式切换尚未完成），**本点丢弃，不按旧模式重复写 RAM，也不重复生成切换任务**。
4. 否则按 `vi_state[channel]` 写 `Voltage/Current Result RAM[channel]`，同时令 `switch_pending[channel]=1`，请求切换到相反模式。

ADC 数据与 Result RAM 写入在采样接收侧完成；**不需要为 ADC 数据做大 FIFO**。切换命令通过 `switch_pending` 128-bit 位图缓存，即使连续多个 `sample_valid` 相隔很近，也不丢失各通道的切换请求。实现时需处理同周期 pending 置位/清除的优先级。

## 5. 切换调度器（单个 FSM，直接读改写）

不使用 Shadow RAM；由当前目标模式决定读回内容、计算增益，再通过同一 AD5560 Driver 逐笔执行。**具体电压阈值、各电流挡位对应的 MEASOUT Gain，以及 0x01 的精确位域数值后续再确定。**

### 5.1 目标为 V：根据 FIN DAC 选择电压 Gain

```text
选中待切换 CH（目标模式 V）
    ↓
READ 0x08 FIN DAC → 等 rsp_valid，锁存当前 FIN DAC x1
    ↓
根据 FIN DAC 码判断应选择的电压测量 Gain
    ↓
READ 0x01 → 等 rsp_valid → 只修改 Gain 对应位 → WRITE 0x01
    ↓
READ 0x02 → 等 rsp_valid → 只修改 MEASOUT 选择位为 V → WRITE 0x02
    ↓
等待最后一笔写完成、Driver ready；确认无 bus_fault
    ↓
vi_state[CH] = V；switch_pending[CH] = 0
```

这里读取的是器件**当前 FIN DAC x1 寄存器码**，用于估算应选择的电压测量增益；它不必然等同于上位机最初设置的最终目标电压（例如 Ramp 过程中）。正常测量切换安排在 System 允许测量的阶段，Gain 的换算关系、切换阈值和边界条件后续确定。

### 5.2 目标为 I：根据电流挡位选择电流 Gain

```text
选中待切换 CH（目标模式 I）
    ↓
READ 0x02 → 等 rsp_valid，提取当前电流挡位
    ↓
根据电流挡位判断应选择的电流测量 Gain
    ↓
READ 0x01 → 等 rsp_valid → 只修改 Gain 对应位 → WRITE 0x01
    ↓
READ 0x02 → 等 rsp_valid → 只修改 MEASOUT 选择位为 I → WRITE 0x02
    ↓
等待最后一笔写完成、Driver ready；确认无 bus_fault
    ↓
vi_state[CH] = I；switch_pending[CH] = 0
```

电流模式必须**先取得 0x02 当前电流挡位**，否则无法在写 0x01 前计算 Gain。为统一读改写流程，这里在最终修改 MEASOUT 选择位前再次读取 0x02；后续确认独占授权与寄存器一致性后，可评估复用第一次读回值，减少一次 READ。

### 5.3 读写事务约束

- `0x01`：保留非 MEASOUT Gain 字段；仅覆盖选定 Gain 的相关位，读回值与写入值由 FSM 临时寄存。
- `0x02`：仅修改 `ME[8:5]` 的测量选择位，保留 SW_INH、电流挡位、Clamp 等其他字段。
- **READ 必须在 `valid && ready` 握手后等待相应 Driver 的 `rsp_valid`，再使用 `rsp_rd_data`**。不可仅凭 Driver ready 当作读数据有效。System/Top 在切换授权前须排空旧 READ 及其响应，避免跨业务混淆。
- WRITE 的 `valid && ready` 只表示命令被接收，不等于完成；下一笔依赖当前寄存器内容的操作须确保前一笔已完成；最终仅在全部写完且无 fault 时更新 `vi_state`。
- 一次通道切换中的读改写须在同一业务授权范围内完成，防止其他业务在读与写之间改动 0x01/0x02，造成旧值覆盖新配置。
- 不同 BUS 的 Driver 可并行执行事务；公共调度器仍是一套 FSM，可利用各 BUS ready 交叉调度。一个通道的多笔 READ/WRITE 必须严格保持先后依赖顺序。
- 如果读回无响应、Driver fault 或 System 禁止继续切换，当前模式不得提前翻转；停止写入模式不确定的 ADC 结果，待重新授权后恢复/重新建立 V 基线。

## 6. 数据有效性约定

第一版采用简化时序：**完成 AD5560 V/I 切换后，默认该通道下一次正常的 `sample_valid` 属于新模式**，不额外设固定延时，也不使用 AD4114 `skip_cnt` 过滤切换后的固定点数。

依据：同一 ADC 通道更新间隔约 161 ms，AD5560 SPI 写通常为微秒量级，正常情况下有较大时间余量。

例外保护：

- 当前通道的切换仍 pending/进行中时，ADC 点不入库。
- 如果 System 中途禁止 SPI、Driver 故障或模式无法确认，不得将该点作为已切换模式的数据保存。
- 这一简化依赖切换在下一次 ADC 有效转换窗口开始前完成且模拟输出稳定；若上板发现极端延迟或跨切换转换问题，再增加按时间/转换轮次丢点保护，不在第一版引入完整 ADC 转换时间追踪。

`vi_state` 表示已确认的实际配置状态，不在收到 `sample_valid` 或提交 SPI 命令时提前翻转。

## 7. System Controller 协作、暂停与恢复

Measurement属于**低优先级后台业务**，将来作为受控业务由System互斥授权整个8BUS Driver资源池。高优先级业务启动前，Measurement先暂停并释放授权；不与Config/Power/Alarm同时提交命令。现阶段不实现Measurement RTL，也不新增sel编码。

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

Alarm/Fault需优先处理，**不能等待全部通道I→V回切完成**。Alarm仍必须等旧业务停止提交及已接受的Driver事务/响应排空后获得授权；bus_fault独立转FAULT，不受普通ready屏障阻塞。Manager 立即停止提交新切换；对尚未完成的切换状态保持待确认/失效处理，不把不确定模式的 ADC 点写入 Result RAM。故障处理完毕且重新允许测量后，再执行模式恢复/重新建立 V 基线。

上电、配置或复位等流程若修改了测量相关寄存器，恢复测量时应先通过 AD5560 READ/WRITE 重新建立 V 模式，不能继续假定旧的 `vi_state` 必然有效；不依赖 Shadow RAM 同步。

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

1. 按 FIN DAC（0x08）读回码确定电压 Gain 的阈值/换算规则；按 0x02 电流挡位确定电流 Gain 的对应表；0x01 Gain 的具体字段值（后续讨论）。
2. 顶层测量命令仲裁及 READ response 路由、`meas_pause / meas_paused` 的具体握手和排空时序。
3. System 重新授权后，逐通道读取/恢复 V 模式的初始化及异常处理策略；读改写期间禁止其他业务交叉修改相关寄存器。
4. 上板验证 V/I 切换相对 ADC 转换窗口的裕量、暂停/故障后的重新同步，以及测量数据的实际刷新周期。

本文件只记录架构讨论，尚未实现 Measurement Manager RTL，也不修改现有 AD4114 采样模块。
