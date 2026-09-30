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

Alarm Status 属于读事务，因此 `cmd_valid && cmd_ready` 仅表示读命令已经提交。Alarm Handler 必须等待 Driver 返回 `rsp_valid`，在读结果有效后才能判断状态并继续扫描下一颗 Device。

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
提交 Alarm Status 读命令
    ↓
等待 rsp_valid
    ↓
读取 rsp_rd_data
    ↓
status != 0 → 写 Result RAM
    ↓
继续下一颗 Device
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

因此初始化流程增加一次全清：

```text
完成 AD5560 配置
    ↓
等待模拟状态稳定
    ↓
alarm_clear_start + alarm_clear_all
    ↓
全部 128 颗依次读取 Alarm Clear (0x44)
    ↓
清除初始化 / 配置过程产生的历史 Latched Alarm
    ↓
进入正式 RUN 状态
```

该操作只用于进入正式运行前建立干净的 Alarm 基线，不作为运行阶段的自动清除机制。

进入 RUN 后仍遵循原规则：Alarm 扫描只读 `0x43`，不读 `0x44`；只有收到明确的 Alarm Clear 命令后才执行 `0x44` 清除。

---

## 5. Alarm Result RAM

Result RAM 使用 `258 × 16 bit`，地址以 16-bit word 为单位。

### 5.1 总体布局

| 区域 | 地址 / 格式 | 说明 |
|---|---|---|
| Header | word 0 | `FAULT_COUNT`，本轮有效 Fault Record 数 |
|  | word 1 | `ALARM_BUS_VECTOR[7:0]`，本轮启动时锁存的 BUS 报警向量 |
| Fault Record | word 2 开始 | 每个有效故障 Device 占 2 word |

### 5.2 Record 格式

| word offset | 内容 |
|---:|---|
| +0 | Record ID：`[6:4] BUS_ID`，`[3:0] DEVICE_ID`，其余保留 |
| +1 | `ALARM_STATUS[15:0]` |

仅当 `ALARM_STATUS != 0` 时生成一条 Record，并：

```text
FAULT_COUNT++
device_fault_vector[{BUS_ID, DEVICE_ID}] = 1
```

新的 `alarm_start` 会清零 `FAULT_COUNT`、写指针和 `device_fault_vector`；无需清空整块 RAM，`FAULT_COUNT` 决定有效 Record 数。

上位机只需读取 Header 和 `FAULT_COUNT` 条 Record。

容量最坏为：

```text
2 + 128×2 = 258 word
```

因此使用 `258 × 16 bit` 即可。后续 Record 格式增加字段时应同步重新计算容量。

公共寄存器读写接口和握手规则统一参考 `AD5560_DRIVER_DESIGN.md`。

---

## 6. 独立 Alarm Clear 流程

Alarm Clear (0x44) 不与扫描绑定，由以下两个输入共同定义：

```text
alarm_clear_start
alarm_clear_all
```

启动时锁存 `alarm_clear_all`，本轮 Clear 过程中不再受输入变化影响。

两种模式：

```text
alarm_clear_all = 0
    → 根据最近一次 device_fault_vector 选择目标
    → 用于运行期故障处理后的定向清除

alarm_clear_all = 1
    → DEV0~127 全部清除
    → 用于初始化稳定后的预清除
```

运行期正常流程：

```text
ALARM
  ↓
Scan 0x43
  ↓
device_fault_vector
  ↓
故障处理
  ↓
alarm_clear_start，alarm_clear_all=0
  ↓
只清本次扫描记录到的故障 Device
```

初始化流程不要求先 Scan：

```text
配置完成并稳定
  ↓
alarm_clear_start，alarm_clear_all=1
  ↓
128 颗全部执行 Alarm Clear
```

Alarm Clear 本身也是 READ 事务。每次 0x44 完成 `valid / ready` 握手后，仍需等待对应的 `rsp_valid`，确认 transaction 已完成；读回数据忽略。

全部目标均完成后产生：

```text
alarm_clear_done
```

Clear 不修改 `device_fault_vector` 和 Result RAM；它们继续保存最近一次扫描快照，直到下一次 `alarm_start`。

Alarm Clear 完成后，共享 ALARM 线是否释放由实际硬件状态决定。

---

## 7. 控制接口

System Controller → Alarm Handler：

```text
alarm_start
alarm_vector[7:0]
alarm_abort
alarm_clear_start
alarm_clear_all
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

### 7.1 abort 优先级

`alarm_abort` 优先于 `alarm_done`。若同周期出现，按 abort 处理，不产生 `alarm_done`。

若 Alarm Handler 正在等待 `rsp_valid` 时收到 `alarm_abort`，立即退出当前流程并回到 IDLE；已经提交给 Driver 的读事务不撤销，之后晚到的 `rsp_valid` 直接忽略。


