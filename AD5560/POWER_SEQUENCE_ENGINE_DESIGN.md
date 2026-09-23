# AD5560 Power Sequence Engine 设计

## 1. 模块定位

`Power Sequence Engine` 负责 AD5560 的完整上电 / 下电流程。

上位机初始化时一次性写入：

- `EN_MASK[127:0]`，定义本次配置实际使用的通道；
- EN_MASK 对应有效通道的上电 / 下电 Ramp 参数；
- 上电 EN Sequence；
- 下电 EN Sequence。

每次重新下发 Power Sequence RAM 数据时，`EN_MASK` 与参数、Sequence 一起更新，视为同一份完整配置。

运行时 System Controller 只发出“上电”或“下电”命令。Power Sequence Engine 自动分两阶段执行：

```text
POWER_ON
   ↓
装载 EN_MASK 有效通道的上电 Ramp 参数
   ↓
执行上电 EN Sequence

POWER_OFF
   ↓
装载 EN_MASK 有效通道的下电 Ramp 参数
   ↓
执行下电 EN Sequence
```

Config Manager 不参与运行期上下电参数切换。

---

## 2. Power Sequence RAM

Power Sequence RAM 直接放在 `Power Sequence Engine` 内部，统一保存上下电所需数据。

逻辑上分为：

```text
1. Header
2. EN_MASK[127:0]
3. 有效通道 Ramp Parameter Records
4. Power-Up Sequence
5. Power-Down Sequence
```

### 2.1 Header

RAM 最前面固定保存 3 个 16-bit word：

```text
word 0 : SEQUENCE_START_ADDR
word 1 : UP_STEP_COUNT
word 2 : DOWN_STEP_COUNT
```

其中：

- `SEQUENCE_START_ADDR` 为 Power-Up Sequence 的起始 word 地址；
- `UP_STEP_COUNT` 为上电 Sequence 的 Step 数量；
- `DOWN_STEP_COUNT` 为下电 Sequence 的 Step 数量；
- 所有地址均以 16-bit word 为单位。

Power-Down Sequence 不单独保存起始地址，由以下关系得到：

```text
UP_SEQUENCE_START   = SEQUENCE_START_ADDR
DOWN_SEQUENCE_START = SEQUENCE_START_ADDR + UP_STEP_COUNT * 9
```

因为每个 Sequence Step 固定占 9 个 16-bit word。

### 2.2 EN_MASK

Header 后紧跟：

```text
EN_MASK[127:0]
```

共占 8 个 16-bit word。

`EN_MASK[n] = 1` 表示通道 n 属于本次 Power Sequence 配置。

Ramp Parameter Table 只保存 EN_MASK 中置 1 通道的参数，不为未使用通道预留固定记录。

Parameter Record 与 EN_MASK 中从低位到高位出现的 `1` 一一对应。

例如：

```text
EN_MASK：CH2、CH17 为 1

Parameter[0] -> CH2
Parameter[1] -> CH17
```

执行时 FPGA 从 bit0 到 bit127 扫描 EN_MASK；遇到一个 `1` 就读取下一条 Parameter Record。

通道号直接得到：

```text
BUS_ID    = channel[6:4]
DEVICE_ID = channel[3:0]
```

不要求额外保存 CHANNEL_ID。

### 2.3 Ramp Parameter Record

每个有效通道保存：

```text
UP_RAMP_END
UP_RAMP_STEP
UP_RCLK_DIV

DOWN_RAMP_END
DOWN_RAMP_STEP
DOWN_RCLK_DIV
```

这些值均为上位机已经计算好的 AD5560 寄存器值，FPGA 不做工程量换算。

第一版每个有效通道占 6 个 16-bit word：

```text
word +0 : UP_RAMP_END
word +1 : UP_RAMP_STEP
word +2 : UP_RCLK_DIV
word +3 : DOWN_RAMP_END
word +4 : DOWN_RAMP_STEP
word +5 : DOWN_RCLK_DIV
```

Channel Parameter Records 紧跟在 EN_MASK 后面，因此其起始地址固定为：

```text
PARAM_START_ADDR = 3 + 8 = 11
```

不需要在 Header 中额外保存。

参数记录数量由 EN_MASK 决定：

```text
CHANNEL_COUNT = popcount(EN_MASK)
PARAM_WORD_COUNT = CHANNEL_COUNT * 6
```

因此参数区结束位置可以直接得到。上位机填写 Header 中的 `SEQUENCE_START_ADDR` 时，应满足：

```text
SEQUENCE_START_ADDR = PARAM_START_ADDR + CHANNEL_COUNT * 6
```

如果后续某个方向还需要额外切换其他 Ramp 寄存器，可扩展 Parameter Record；此时只需同步修改单条 Parameter Record 的固定 word 数和上述地址计算关系。

### 2.4 EN Sequence

上电、下电分别保存独立 Sequence。

每一步继续采用：

```text
EN_State[127:0]
Delay_ms[15:0]
```

每一步固定占 9 个 16-bit word：

```text
word 0..7 : EN_State[127:0]
word 8    : Delay_ms
```

Power-Up 和 Power-Down Sequence 共用 Header 中的 StepCount 信息，不在 Sequence 数据区重复保存数量。

RAM 总体布局为：

```text
word 0                SEQUENCE_START_ADDR
word 1                UP_STEP_COUNT
word 2                DOWN_STEP_COUNT
word 3..10             EN_MASK[127:0]
word 11..              Channel Parameter Records
SEQUENCE_START_ADDR..  Power-Up Sequence
                       Power-Down Sequence
```

其中 Power-Down Sequence 紧跟 Power-Up Sequence。

### 2.5 RAM 容量计算

当前 Power Sequence RAM 统一采用 16-bit word。

固定区域：

```text
Header                 = 3 word
EN_MASK[127:0]         = 8 word
固定区域合计           = 11 word
```

Channel Parameter Records：

```text
CHANNEL_COUNT         = 128
每个有效通道           = 6 word

PARAM_WORDS           = 128 × 6 = 768
```

Power-Up / Power-Down Sequence：

```text
每个 Step              = 9 word
上、下电各预留 32 个 step

UP_SEQUENCE_WORDS      = 32 × 9 = 288
DOWN_SEQUENCE_WORDS    = 32 × 9 = 288
```

因此当前结构的总容量为：

```text
TOTAL_WORDS = 11 + 768 + 288 + 288 = 1355
```

因此第一版 RAM 按：

```text
1355 × 16 bit
```



后续如果 Header、Parameter Record 或 Step 格式发生变化，应同步重新计算本节 RAM 容量。

---

## 3. 控制接口

System Controller 提供流程控制：

```text
seq_start
seq_mode          // POWER_ON / POWER_OFF
seq_abort
```

另外，顶层将 8 个 Driver 的 `cmd_ready` 汇总后直接提供给 Power Sequence Engine：

```text
seq_bus_ready[7:0]
```

`seq_bus_ready` 仅用于 PSE 内部选择下一笔可派发的 BUS，不经过 System Controller 做 BUS 仲裁。

Power Sequence Engine 返回：

```text
seq_busy
seq_done
```

`seq_start` 有效时锁存 `seq_mode`，之后整个流程由 Power Sequence Engine 自主完成。

第一版不允许执行过程中切换 `seq_mode`。

---

## 4. 第一阶段：Ramp 参数装载

收到 `seq_start` 后，Power Sequence Engine 先根据 `seq_mode` 选择对应方向的 Ramp 参数。

POWER_ON 时写：

```text
Ramp End Code
Ramp Step Size
RCLK Divider
```

对应每颗 AD5560 的上电参数。

POWER_OFF 时写同样三个寄存器，但数据来自下电参数表。

Ramp 参数装载阶段不会启动 Ramp，只是预先设置下一次 Ramp 所需参数。

### 4.1 并行装载

参数装载同样利用 8 条 SPI BUS 并行执行。

每个 BUS 独立维护当前需要配置的 DEVICE。只要某个 BUS 对应 Driver ready，就可以向该 BUS 派发下一条参数写命令。

各 BUS 只处理 EN_MASK 中属于本 BUS 的有效 DEVICE。例如某 BUS 仅 DEV2、DEV7 有效，则只派发这两颗器件的参数。

8 条 BUS 可以同时执行。

同一颗器件的 Ramp 参数按固定寄存器顺序写入即可。

### 4.2 参数装载完成

EN_MASK 中所有有效通道的本方向 Ramp 参数均完成命令握手后，不能立即启动 EN Sequence。

Power Sequence Engine 必须等待：

```text
seq_bus_ready == 8'hFF
```

即 8 个 Driver 全部恢复 ready，确认最后一批 Ramp 参数的 SPI / BUSY 流程已经真正结束，再进入 EN Sequence。

---

## 5. 第二阶段：EN Sequence

Ramp 参数全部装载完成后，开始执行对应方向的 EN Sequence。

模块内部保存：

```text
current_state[127:0]
target_state[127:0]
```

读取一个 Step 后：

```text
change_mask = (current_state ^ target_state) & EN_MASK
```

只有 EN_MASK 内且状态发生变化的通道需要触发 Ramp；EN_MASK 外的通道在整个 Power Sequence 中忽略。

对于这些通道，Power Sequence Engine 产生固定命令：

```text
REG_ADDR = Enable Ramp Register
REG_DATA = 16'hFFFF
```

因为 Ramp End / Step / Divider 已经在第一阶段全部设置完成，Sequence 阶段不再修改这些参数。

上电和下电触发 Ramp 使用相同的 Enable Ramp 命令，实际方向由当前 FIN DAC 状态和已装载的 Ramp End 参数决定。

---

## 6. 8 BUS pending 调度

有效通道的变化按照 8 条物理 BUS 拆成：

```text
BUS0 pending = change_mask[15:0]
BUS1 pending = change_mask[31:16]
...
BUS7 pending = change_mask[127:112]
```

模块内部维护：

```text
pending_mask[7:0][15:0]
pending_bus[7:0]
```

并根据：

```text
available_bus = pending_bus & seq_bus_ready
```

选择当前可派发 BUS。

如果 BUS0 正忙，但 BUS1 / BUS2 有 pending 且 ready，应继续派发 BUS1 / BUS2，不允许被 BUS0 阻塞。

同一 BUS 内按 DEVICE_ID 顺序执行；不同 BUS 的 SPI 事务允许重叠。

第一版 BUS 选择采用固定优先级即可，不要求公平仲裁。

每次寄存器命令完成 `valid / ready` 握手后：

- 参数装载阶段：推进到该 BUS 的下一条 Ramp 参数；
- Sequence 阶段：清除对应 BUS / DEVICE 的 pending bit；
- 不等待 Driver 完成本次 SPI / BUSY 流程。

公共寄存器命令接口和握手规则统一参考 `AD5560_DRIVER_DESIGN.md`。

---

## 7. Step 完成与 Delay

一个 Step 的全部 `pending_mask` 清零后，表示该 Step 中所有需要变化的通道都已完成 Ramp Enable 命令握手。

此时：

```text
current_state = target_state
```

然后开始本 Step 的 `Delay_ms`。

Delay 定义为：

> 当前 Step 的全部 Ramp Enable 命令完成握手之后，到下一 Step 开始派发之间的时间。

Delay 结束后读取下一 Step。

最后一个 Step 完成并满足流程结束条件后产生 `seq_done`。

---

## 8. abort



收到 `seq_abort` 后：

```text
停止参数装载 / Sequence
取消尚未握手的 seq_cmd_valid
清除 pending
seq_busy = 0
回到 IDLE
```

已经完成握手进入 Driver 的事务由 Driver 自行结束。


