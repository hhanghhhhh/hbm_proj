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

RAM 使用 `2048 × 16 bit`。所有地址均以 16-bit word 为单位。

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
|  | +4 | `DOWN_RAMP_END` |
|  | +5 | `DOWN_RAMP_STEP` |
|  | +6 | `DOWN_RCLK_DIV` |
| Sequence Step | +0..7 | `TRIGGER_MASK[127:0]`，word0→CH[15:0]，word7→CH[127:112] |
|  | +8 | `Delay_ms` |

Parameter Record 属于哪条 BUS，由对应 `BUSx_PARAM_START / COUNT` 决定；同 BUS 内建议按 DEVICE_ID 递增排列。

`TRIGGER_MASK[n]=1` 表示该 Step 对 Channel n 执行 Ramp Enable，其中：

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

## 4. 空 Sequence

读取 Header 后，根据 mode 选择：

```text
POWER_ON  -> UP_STEP_COUNT
POWER_OFF -> DOWN_STEP_COUNT
```

如果本方向 `STEP_COUNT=0`：

```text
不装载 Ramp 参数
不执行 Sequence
直接 seq_done
```

---

## 5. Ramp 参数装载

每条 BUS 独立维护：

```text
param_ptr[bus]
param_left[bus]
param_phase[bus]
device_id[bus]
```

初始化：

```text
param_ptr  = BUSx_PARAM_START
param_left = BUSx_PARAM_COUNT
```

当：

```text
param_left != 0
&& 对应 Driver ready
```

即可调度该 BUS。

每个 Record 执行：

```text
读 DEVICE_ID
    ↓
写 0x3E Ramp End
    ↓
写 0x3F Ramp Step
    ↓
写 0x40 RCLK Divider
    ↓
param_ptr += 7
param_left--
```

不同 BUS 可交叉派发。

如果 BUS0 busy，而 BUS1 ready，必须继续派发 BUS1，不允许 BUS0 阻塞其他 BUS。

公共命令完成 `valid / ready` 握手后即认为该寄存器命令已提交，不等待 SPI/BUSY 完成。

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

第一版 BUS / Channel 选择使用固定优先级，不要求公平仲裁。

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

