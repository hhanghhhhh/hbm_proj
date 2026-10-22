# AD5560 Power Sequence Engine 设计

## 1. 模块定位

`Power Sequence Engine` 负责 AD5560 的上电 / 下电 Ramp 参数装载和 Sequence 执行。


运行流程：

```text
POWER_ON / POWER_OFF
        ↓
读取 Header
        ↓
按 BUS 装载本方向 Ramp 参数
        ↓
等待 8 个 Driver 全部 ready
        ↓
逐 Step 执行 TRIGGER_MASK
        ↓
Delay_ms
        ↓
seq_done
```

---

## 2. Power Sequence RAM

RAM 使用 `2048 × 16 bit`。所有地址均以 16-bit word 为单位。**Power Sequence RAM Image 统一采用大端字节序**：

- **上位机下发的每个 16-bit word 均采用大端传输**：先高字节 `[15:8]`、后低字节 `[7:0]`，例如 `16'h1234` 在 `POWER_SEQUENCE_DATA` 的 `DATA` 中按 `8'h12, 8'h34` 发送，FPGA 写入 RAM 的 16-bit 数据为 `16'h1234`，不交换字节。
- 多个 16-bit word 按 RAM 地址从低到高依次传输；对于跨多个 word 的整体数据（如 128-bit `TRIGGER_MASK`），**高位 word 存低地址，低位 word 存高地址**。
- RAM Image 的 CRC-16/MODBUS 按地址递增，且每个 word 按 `[15:8] → [7:0]` 顺序计算。

### 2.1 总体布局

| 区域 | 地址 / 格式 | 说明 |
|---|---|---|
| Header | word 0 | `UP_SEQUENCE_START` |
|  | word 1 | `UP_STEP_COUNT` |
|  | word 2 | `DOWN_SEQUENCE_START` |
|  | word 3 | `DOWN_STEP_COUNT` |
|  | word 4..11 | `BUS0..7_PARAM_START` |
|  | word 12..19 | `BUS0..7_PARAM_COUNT` |
| BUS Parameter | Header 指定 | 每个 Device 1 条 Parameter Record |
| Power-Up Sequence | `UP_SEQUENCE_START` | 每 Step 9 word |
| Power-Down Sequence | `DOWN_SEQUENCE_START` | 每 Step 9 word |

### 2.2 Record 格式

| 类型 | word offset | 内容 |
|---|---:|---|
| Parameter Record | +0 | `DEVICE_ID[3:0]` |
|  | +1 | `UP_RAMP_END` |
|  | +2 | `UP_RAMP_STEP` |
|  | +3 | `UP_RCLK_DIV` |
|  | +4 | `CONTROL_REG_0x02[14:0]`，仅 Power-On 使用；bit15(SW_INH) 由 FPGA 强制写 1 |
|  | +5 | `DOWN_RAMP_STEP` |
|  | +6 | `DOWN_RCLK_DIV` |
| Sequence Step | +0..7 | `TRIGGER_MASK[127:0]`，按大端排列：word0→CH[127:112]、word1→CH[111:96]、…、word7→CH[15:0] |
|  | +8 | `Delay_ms` |

Parameter Record 属于哪条 BUS，由对应 `BUSx_PARAM_START / COUNT` 决定；同 BUS 内建议按 DEVICE_ID 递增排列。

其中：

- Power-On 的 `FIN DAC(0x08)` 固定写 `16'h0000`，作为 Ramp 起始值，因此不占 RAM 字段；
- Power-Down 的 `Ramp End(0x3E)` 固定写 `16'h0000`，因此不需要上位机下发 `DOWN_RAMP_END`；
- `CONTROL_REG_0x02` 当前仅用于 Power-On，上位机提供寄存器 `0x02` 的其它控制位，FPGA 写出时强制 `SW_INH(bit15)=1`；
- Power-Off 的 Parameter 阶段暂不修改 `0x02 / SW_INH`；Ramp 到 0 V 后如何进入最终关断状态，后续单独设计。

`TRIGGER_MASK[n]=1` 表示该 Step 对 Channel n 执行 Ramp Enable。128-bit Mask 的最高位为 CH127、最低位为 CH0；每个 word 内同样先存高字节、后存低字节。例如仅 CH0 置 1 时，8 个 word 为 `0000 0000 0000 0000 0000 0000 0000 0001`。

其中：

```text
BUS_ID    = channel[6:4]
DEVICE_ID = channel[3:0]
```

FPGA 不再维护 `EN_MASK / current_state / target_state / change_mask`，执行信息均由上位机写入 RAM。

容量最坏为：

```text
20 + 128×7 + 32×9 + 32×9 = 1492 word
```

因此 `2048 × 16 bit` 有足够余量。

---

## 3. 控制接口

```text
seq_start
seq_mode          // 0: POWER_ON, 1: POWER_OFF
seq_abort

seq_bus_ready[7:0]

seq_busy
seq_done
```

仅在 `seq_busy=0` 时接受 `seq_start`。

接受后锁存 `seq_mode`。

`seq_busy=1` 时重复 `seq_start`：

- 忽略；
- 不重新启动；
- 不修改当前进度；
- 不重新锁存 mode。


---

## 5. Ramp 参数装载

每条 BUS 独立维护：

```text
param_ptr[bus]：当前 BUS 正在处理的 Parameter Record 起始地址。
每完成一个 Device param_ptr += 7
 
param_left[bus]：当前 BUS 还剩多少条 Parameter Record。
每完成一个 Device param_left--

param_phase[bus]：当前一条 Parameter Record 内的寄存器配置执行到哪一步。
Power-On 以 `0x02` Control Register 作为最后一步；Power-Off 当前以 RCLK Divider 作为最后一步。

device_id[bus]：当前 BUS 正在操作的 device id
```


当：

```text
param_left != 0
&& 对应 Driver ready
```

即可调度该 BUS。

每个 Record 根据 `seq_mode` 执行不同的 Parameter 写入序列。

Power-On：

```text
读 DEVICE_ID
    ↓
写 0x08 FIN DAC = 16'h0000
    ↓
写 0x3E Ramp End = UP_RAMP_END
    ↓
写 0x3F Ramp Step = UP_RAMP_STEP
    ↓
写 0x40 RCLK Divider = UP_RCLK_DIV
    ↓
写 0x02 Control Register = {SW_INH=1, CONTROL_REG_0x02[14:0]}
    ↓
param_ptr += 7
param_left--
```

其中 `FIN DAC=0` 用于建立本次 Power-On Ramp 的 0 V 起始值。

Power-Off：

```text
读 DEVICE_ID
    ↓
写 0x3E Ramp End = 16'h0000
    ↓
写 0x3F Ramp Step = DOWN_RAMP_STEP
    ↓
写 0x40 RCLK Divider = DOWN_RCLK_DIV
    ↓
param_ptr += 7
param_left--
```

Power-Down 不修改 `FIN DAC(0x08)`；Ramp End 固定为 0，因此无需从 RAM 读取。

`0x02` Control Register 当前只在 Power-On Parameter 阶段最后写，`SW_INH(bit15)` 强制为 1。Power-Off 不修改该寄存器。

不同 BUS 可交叉派发。


所有 `param_left == 0` 后进入完成屏障：

```text
等待 seq_bus_ready == 8'hFF
```

确认最后一批参数写真正完成后再执行 Sequence。

---

## 6. Sequence 执行

读取一个 Step 后直接：

```text
pending_mask = TRIGGER_MASK
```

不再做状态差分或 EN_MASK 过滤。

调度规则：

```text
pending bit = 1
&& 对应 BUS ready
        ↓
Write 0x41 = 16'hFFFF
        ↓
valid / ready 握手
        ↓
清对应 pending bit
```

同 BUS 内按 DEVICE_ID 低编号优先。

不同 BUS 中，busy BUS 不阻塞其他 ready BUS。


---

## 7. Step 完成与 Delay

当：

```text
pending_mask == 0
```

表示当前 Step 的 Ramp Enable 命令全部完成提交。

随后开始本 Step 的 `Delay_ms`。

Delay 定义：

> 当前 Step 最后一条 Ramp Enable 完成握手，到下一 Step 开始派发之间的时间。

Delay=0 时直接进入下一 Step。

最后一个 Step 完成后产生：

```text
seq_done = 1 pulse
seq_busy = 0
```

---

## 8. abort

`seq_abort` 优先于正常完成。

收到 abort 后：

```text
取消尚未握手的 cmd_valid
清除 pending
seq_busy = 0
回到 IDLE
```

已经完成握手交给 Driver 的事务不撤销。

故障后不自动恢复原 Sequence，由 System Controller 进入故障处理流程。

