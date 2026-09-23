# AD5560 Alarm Handler 设计

## 1. 模块定位

`Alarm Handler` 负责在 AD5560 `ALARM[7:0]` 触发后，对报警 BUS 上的器件进行扫描定位，并将故障信息保存到内部 Result RAM，供上位机后续读取。

Alarm Handler 只负责：

- 根据 System Controller 提供的 `alarm_vector[7:0]` 扫描报警 BUS；
- 读取各 Device 的 Alarm Status；
- 保存真正有报警的 Device 信息；
- 生成 `device_fault_vector[127:0]`，指示具体故障 Device；
- 在收到独立的清除命令后执行 Alarm Clear。


---

## 2. 控制流程

System Controller 检测到 `ALARM[7:0]` 后，先锁存报警 BUS，再启动 Alarm Handler：

```text
ALARM[7:0]
    ↓
System Controller
    ↓ alarm_start + alarm_vector[7:0]
Alarm Handler
```

Alarm Handler 在 `alarm_start` 时锁存本轮 `alarm_vector`，本轮扫描只依据锁存值执行，不根据实时 ALARM 电平提前停止。

基本流程：

```text
alarm_start
    ↓
锁存 alarm_vector
    ↓
FAULT_COUNT = 0
    ↓
依次检查 alarm_vector 中置 1 的 BUS
    ↓
每个报警 BUS 固定扫描 DEV0 ~ DEV15
    ↓
读取 Alarm Status
    ↓
status != 0 → 写 Result RAM
    ↓
全部报警 BUS 扫描完成
    ↓
alarm_done
```

---

## 3. BUS / Device 扫描规则

一条 BUS 的 ALARM 由本 BUS 的 16 颗 AD5560 共用，因此只要：

```text
alarm_vector[bus] = 1
```

就必须扫描该 BUS 的：

```text
DEV0 ~ DEV15
```



未置位的 BUS 直接跳过，不做扫描。

---

## 4. 扫描阶段只读，不清除

扫描阶段只读取 Alarm Status (0x43)，不执行 Alarm Clear (0x44)。



原因：

- 扫描本身只用于定位和保存故障快照；
- 清除 Alarm 后共享 ALARM 线可能发生变化；
- 在上位机明确要求清除之前，没有必要改变当前硬件故障状态；
- 保持 Alarm 状态有利于后续诊断和确认。

因此“扫描”和“清除”是两个独立流程。

### 4.1 初始化稳定后的预清除

AD5560 上电、量程切换、Clamp / Force / Sense 等配置过程中，模拟状态尚未稳定，可能产生瞬时 Alarm 毛刺。若 Alarm 配置为 Latched 模式，这类瞬时报警会被锁存并一直保持。

因此初始化流程增加一次预清除：

```text
完成 AD5560 配置
    ↓
等待模拟状态稳定
    ↓
读取 Alarm Clear (0x44)
    ↓
清除初始化 / 配置过程产生的历史 Latched Alarm
    ↓
进入正式 RUN 状态
```

该操作只用于进入正式运行前建立干净的 Alarm 基线，不作为运行阶段的自动清除机制。

进入 RUN 后仍遵循原规则：Alarm 扫描只读 `0x43`，不读 `0x44`；只有收到明确的 Alarm Clear 命令后才执行 `0x44` 清除。

---

## 5. Alarm Result RAM

Alarm Handler 内部保存一块 Result RAM。

第一版采用：

```text
word 0 : FAULT_COUNT
word 1 : ALARM_BUS_VECTOR

word 2 : Record0 ID
word 3 : Record0 ALARM_STATUS

word 4 : Record1 ID
word 5 : Record1 ALARM_STATUS
...
```

### 5.1 Header

`FAULT_COUNT` 表示本轮扫描实际发现多少颗有报警状态的 Device。

`ALARM_BUS_VECTOR` 保存本轮 `alarm_start` 时锁存的 BUS 报警向量，低 8 bit 有效。

每次新的扫描开始时：

```text
FAULT_COUNT = 0
write_ptr   = Record0
device_fault_vector[127:0] = 0
```

不需要清空整块 Result RAM，`FAULT_COUNT` 决定有效 Record 数量。

### 5.2 Record

每个有效故障 Device 占 2 个 16-bit word：

```text
Record ID:
[15:7] Reserved
[6:4]  BUS_ID
[3:0]  DEVICE_ID

Record Status:
[15:0] ALARM_STATUS
```

只有：

```text
ALARM_STATUS != 0
```

时才写入一条 Record，并：

```text
FAULT_COUNT++
device_fault_vector[channel_id] = 1
```

其中：

```text
channel_id = {BUS_ID, DEVICE_ID}
```


因此上位机只需要读取：

```text
FAULT_COUNT
FAULT_COUNT × Record
```

不需要读取全部 128 个 Device 的结果。

最坏情况下 128 个 Device 全部有报警：

```text
2 + 128 × 2 = 258 个 16-bit word
```

### 5.3 RAM 容量计算

Alarm Result RAM 固定按最坏情况支持 128 个 Device 全部产生故障记录：

```text
Header                 = 2 word
每个 Fault Record      = 2 word
最大 Fault Record 数   = 128

ALARM_RAM_WORDS        = 2 + 128 × 2
                       = 258 word
```

因此第一版 Alarm Result RAM 按：

```text
258 × 16 bit
```



后续如果 Alarm Record 格式增加字段，应同步重新计算本节 RAM 容量。

公共寄存器读写接口和握手规则统一参考 `AD5560_DRIVER_DESIGN.md`。

---

## 6. 独立 Alarm Clear 流程

Alarm Clear (0x44) 不与扫描绑定。

除“初始化稳定后的预清除”外，正式 RUN 阶段在上位机明确下发清除故障命令之前，Alarm Handler 不清除任何器件 Alarm。

清除流程由独立控制命令启动，例如：

```text
alarm_clear_start
```

第一版 Alarm Clear 可直接根据 `device_fault_vector[127:0]` 选择需要清除的 Device：

```text
device_fault_vector
    ↓
扫描置 1 bit
    ↓
得到 BUS_ID + DEVICE_ID
    ↓
执行对应 Device 的 Alarm Clear
```

Result RAM 继续保留详细的 Alarm Status，`device_fault_vector` 负责快速定位和清除目标选择。

这样不需要重新扫描全部 Device，也不会清除未记录的器件状态。

清除完成后产生：

```text
alarm_clear_done
```

Alarm Clear 完成后，器件共享 ALARM 线是否释放由实际硬件状态决定。

---

## 7. 控制接口

System Controller → Alarm Handler：

```text
alarm_start
alarm_vector[7:0]
alarm_abort
alarm_clear_start
```

Alarm Handler → System Controller / 外部模块：

```text
alarm_busy
alarm_done
alarm_clear_busy
alarm_clear_done
device_fault_vector[127:0]
```

`device_fault_vector` 表示最近一次 Alarm 扫描中定位到的具体故障 Device，可用于：

- 外部模块快速判断具体故障通道；
- 后续 Alarm Clear 选择目标 Device；
- 上位机或系统状态逻辑快速读取故障分布。

该向量在新的 `alarm_start` 时清零，并在扫描过程中根据实际 Alarm Status 逐位置位。

Result RAM 对通信 / 上位机提供只读接口：

```text
alarm_result_rd_addr
alarm_result_rd_data[15:0]
```

运行扫描或清除流程期间，不允许上位机改写 Result RAM。


