# Power Sequence Engine RTL 代码说明

对应：

```text
AD5560/rtl/power_sequence_engine.v
```

本文只解释 RTL 怎么工作，不重复器件背景。


## 2. 状态机分组

虽然 RTL 仍有多个状态，但实际上只分 5 组：

```text
启动：
IDLE
HEADER_REQ / HEADER_LOAD / HEADER_DECIDE

参数阶段：
PARAM_SCHED
PARAM_REQ / PARAM_LOAD
PARAM_SEND
PARAM_BARRIER

Sequence 读取：
STEP_REQ / STEP_LOAD

Sequence 派发：
SEQ_SCHED / SEQ_SEND

收尾：
DELAY
STEP_ADVANCE
```

REQ/LOAD 两状态只是为了适配同步 RAM 的 1 clk 读延迟。


---

## 4. 每条 BUS 只维护四类信息

参数阶段每条 BUS 只维护下面四类信息：

```text
param_ptr[bus]
param_left[bus]
param_phase[bus]
param_device_id[bus]
```

### param_ptr

当前 BUS 正在处理的 Parameter Record 起始地址。每完成一个 Device：

```text
param_ptr += 7
```

### param_left

当前 BUS 还剩多少条 Parameter Record。每完成一个 Device：

```text
param_left--
```

### param_phase

`param_phase` 同时表示“DEVICE_ID 是否已经读取”和“三个参数写到哪一步”：

```text
0 -> 读取 DEVICE_ID
1 -> 写 0x3E Ramp End
2 -> 写 0x3F Ramp Step
3 -> 写 0x40 RCLK Divider
```


---

## 5. 参数调度器怎么工作

`ST_PARAM_SCHED` 检查 8 条 BUS：

```text
param_left != 0
&& Driver ready
```

满足就可以选中。

固定优先级：

```text
BUS0 -> BUS1 -> ... -> BUS7
```

如果 BUS0 busy，而 BUS1 ready：

```text
直接选 BUS1
```

因此一个 BUS 不会把其他 BUS 卡住。

### Scheduler 组合逻辑什么时候更新

`param_select_valid / param_select_bus / param_all_done` 来自 `always @(*)`，它们不是寄存器，没有自己的更新周期。

只要下面任意输入发生变化：

```text
param_left[0..7]
i_seq_bus_ready[0..7]
```

组合逻辑就会立即重新计算结果。

可以理解为：

```text
param_left + bus_ready
        ↓
   Priority Encoder
        ↓
select_valid / select_bus
```

真正把本次选择保存下来的是时序逻辑：

```verilog
selected_bus <= param_select_bus;
```

所以：

```text
param_select_bus = 当前组合逻辑实时算出的候选 BUS
selected_bus     = 时钟沿已经锁存、本次事务真正使用的 BUS
```

### for 循环为什么不会产生 multiple driver

Scheduler 中的 `for` 是组合逻辑描述，综合时会展开成固定的优先级选择逻辑，并不是硬件在一个周期内依次执行 8 次。

当前写法等价于：

```text
if BUS0 available
    select BUS0
else if BUS1 available
    select BUS1
else if BUS2 available
    select BUS2
...
else if BUS7 available
    select BUS7
```

因此如果 8 个 BUS 全部满足条件：

```text
param_select_valid = 1
param_select_bus   = 0
```

BUS0 优先级最高。

原因是循环开始时：

```verilog
param_select_valid = 1'b0;
```

BUS0 命中后使用阻塞赋值立即变为：

```verilog
param_select_valid = 1'b1;
param_select_bus   = 3'd0;
```

后续 BUS1~BUS7 再判断：

```verilog
!param_select_valid
```

已经为假，因此不会再次覆盖选择结果。

这不属于 multiple driver，因为所有对 `param_select_bus` 的赋值都在同一个 `always @(*)` 块内，综合后是一个 priority encoder / mux 网络。

真正的 multiple driver 通常是同一个信号被两个独立的 `always` 块或其他独立驱动源同时驱动。

选中 BUS 后统一进入：

```text
PARAM_REQ
    ↓
PARAM_LOAD
```

`PARAM_REQ` 根据 `param_phase` 决定 RAM 地址：

```text
phase=0 -> 读 DEVICE_ID
phase=1 -> 读 Ramp End
phase=2 -> 读 Ramp Step
phase=3 -> 读 RCLK Divider
```

`PARAM_LOAD` 再根据 phase 判断读回数据的用途：

```text
phase=0
    ↓
锁存 DEVICE_ID
phase=1
    ↓
回 PARAM_SCHED

phase=1/2/3
    ↓
生成对应寄存器写命令
    ↓
PARAM_SEND
```

因此 ID 和参数共用同一套 RAM 读取状态，不需要分别维护 ID_REQ/LOAD 和 DATA_REQ/LOAD。

---

## 6. 为什么写一个 Device 的三个寄存器之间还会回 Scheduler

例如 BUS0 DEV2：

```text
写 0x3E
   ↓ handshake
回 PARAM_SCHED
```

此时 BUS0 Driver 通常已经 busy。

如果 BUS1 ready：

```text
先去给 BUS1 发命令
```

等 BUS0 再次 ready 后，再回来写 DEV2 的 0x3F。

这样才能真正利用 8 条 SPI BUS 并行工作。

如果把一个 Device 的三个寄存器一次性死等写完，BUS0 busy 时公共命令口就会浪费，其他 BUS 也无法及时派发。

---

## 7. Parameter Record 什么时候完成

只有 `param_phase == 3` 的 0x40 完成 handshake 后，才认为当前 Record 完成：

```text
param_phase = 0
param_ptr += 7
param_left--
```

回到 `phase=0` 后，下次再调度这条 BUS 就会读取下一条 Record 的 DEVICE_ID。

当 8 条 BUS：

```text
param_left 全部为 0
```

进入：

```text
ST_PARAM_BARRIER
```

然后等待：

```text
i_seq_bus_ready == 8'hFF
```

因为 `param_left=0` 只代表所有命令已经提交，不代表最后的 SPI/BUSY 已经结束。

---

## 8. Sequence 为什么简单很多

进入 Sequence 后，一个 Step 直接把 RAM 的 8 个 word 装进：

```text
pending_mask[127:0]
```

也就是说：

```text
pending_mask = TRIGGER_MASK
```

没有：

```text
current_state
target_state
change_mask
EN_MASK
```

上位机已经提前算好了谁需要 Ramp。

---

## 9. Sequence 调度

`ST_SEQ_SCHED` 从 CH0 到 CH127 查找：

```text
pending_mask[channel] == 1
&& 对应 BUS ready
```

找到后直接生成：

```text
BUS_ID    = channel[6:4]
DEVICE_ID = channel[3:0]
REG_ADDR  = 0x41
REG_DATA  = 0xFFFF
```

进入 `ST_SEQ_SEND`。

握手完成：

```text
pending_mask[channel] = 0
```

然后重新调度。

所以：

- 同 BUS 内低 DEVICE_ID 优先；
- busy BUS 自动跳过；
- 其他 ready BUS 可以继续工作。

---

## 10. Delay 和 Step 推进

当：

```text
pending_mask == 0
```

当前 Step 的 Ramp Enable 已全部提交。

如果：

```text
Delay_ms == 0
```

直接进入 `ST_STEP_ADVANCE`。

否则进入 `ST_DELAY`。

Delay 从最后一条 Ramp Enable handshake 后开始计时。

下一 Step：

```text
step_base_addr += 9
step_index++
```

最后一个 Step 完成后：

```text
o_seq_done = 1 pulse
o_seq_busy = 0
```

---

## 11. abort

执行过程中：

```text
i_seq_abort && o_seq_busy
```

立即：

```text
o_cmd_valid = 0
pending_mask = 0
o_seq_busy = 0
回 IDLE
```

尚未握手的命令被取消。

已经 valid/ready 握手交给 Driver 的事务不会撤销。

系统故障后不会从这里自动恢复 Sequence。



