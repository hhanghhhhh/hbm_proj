# Alarm Handler RTL 代码说明

对应：

```text
AD5560/rtl/alarm_handler.v
```

Result RAM 格式及系统级流程统一见：

```text
AD5560/design/ALARM_HANDLER_DESIGN.md
```

本文只解释 RTL 如何执行扫描、保存结果和 Alarm Clear。

---

## 1. 整体流程

Alarm Handler 有两个互相独立的工作流程：

```text
Alarm Scan
    读取 0x43
    定位真正故障 Device
    保存 Result RAM / fault vector

Alarm Clear
    根据 fault vector
    读取 0x44 清除对应 Device
```

两种流程共用同一套 Driver 命令接口，但同一时刻只执行一种。



---

## 10. device_fault_vector

`o_device_fault_vector[127:0]` 是最近一次扫描过程中发现的具体故障 Device。

映射关系：

```text
channel_id = {BUS_ID[2:0], DEVICE_ID[3:0]}
```

每次新的 alarm_start：

```text
device_fault_vector = 0
```

只有读取 0x43 得到非零状态时，对应 bit 才置 1。

当 `clear_all=0` 时，这个向量作为后续 Alarm Clear 的目标列表。

---

## 11. Alarm Clear

Clear 由两个输入启动：

```text
i_alarm_clear_start
i_alarm_clear_all
```

在 `alarm_clear_start` 时锁存：

```text
clear_all_reg = i_alarm_clear_all
```

之后本轮流程只看 `clear_all_reg`，外部再改变输入不会影响当前 Clear。

`clear_channel_id` 从 0 到 127 顺序扫描，目标选择条件为：

```text
clear_all_reg == 1
        或
device_fault_vector[channel] == 1
```

因此有两种模式：

```text
clear_all = 0
    -> 只清最近一次 Scan 发现的故障 Device

clear_all = 1
    -> CH0~127 全部执行 Clear
```

命令字段固定为：

```text
BUS_ID    = clear_channel_id[6:4]
DEVICE_ID = clear_channel_id[3:0]
REG_ADDR  = 0x44
RW        = READ
```

0x44 的读回数据本身不用处理，但仍必须等待 `i_rsp_valid`，确认 transaction 完成后才能继续下一 Channel。

所以典型使用是：

```text
初始化稳定后：
clear_all = 1
    -> 不需要先 Scan，直接清全部 128 颗

运行期故障处理后：
clear_all = 0
    -> 根据 device_fault_vector 定向清除
```

全部目标完成后产生 `alarm_clear_done`。

---

## 12. 为什么 Clear 后不清 device_fault_vector

当前 RTL 不在 Clear 时清除 device_fault_vector。

这个向量表示最近一次 Alarm 扫描发现了哪些 Device，也是故障快照的一部分。

Clear 只改变 AD5560 内部 Latched Alarm 状态，不修改已经保存的诊断结果。

下一次新的 alarm_start 才会清空并重新生成 fault vector。

---

## 13. abort

扫描或 Clear 过程中：

```text
i_alarm_abort = 1
```

立即：

```text
回 IDLE
busy = 0
cmd_valid = 0
```

已经完成 valid/ready 握手交给 Driver 的 READ 不撤销。

因此 abort 后如果该 READ 稍后返回 rsp_valid，因为状态机已经不在 SCAN_WAIT_RSP / CLEAR_WAIT_RSP，该 response 会被直接忽略。

Result RAM 的写使能也通过 !i_alarm_abort 做了门控，abort 同周期不会再启动新的 RAM 写入。

---

## 14. 两个 busy 的含义

扫描流程使用：

```text
o_alarm_busy
o_alarm_done
```

Clear 流程使用：

```text
o_alarm_clear_busy
o_alarm_clear_done
```

两套流程共用一个 FSM，因此不会同时执行。

busy 期间新的 start 信号不会被接受。

在 IDLE 中如果 alarm_start 和 alarm_clear_start 同时出现，当前 RTL 的判断顺序会优先接受 alarm_start。


---

## 16. 完整流程压缩图

```text
alarm_start
    ↓
锁存 alarm_vector
    ↓
SCAN_FIND_BUS ── BUS未报警 ──> 下一 BUS
    ↓ 报警 BUS
DEV0 → READ 0x43 → WAIT rsp_valid
    ↓
status != 0 ? ── Yes ──> 写 Record / fault bit
    ↓ No                     ↓
    └──────────────> SCAN_ADVANCE
                           ↓
                    DEV1 ... DEV15
                           ↓
                        下一 BUS
                           ↓
                      写 Header
                           ↓
                      alarm_done
```

Clear：

```text
alarm_clear_start
       ↓
锁存 clear_all
       ↓
扫描 Channel 0~127
       ↓
clear_all=1 或 fault bit=1 ?
       ├─ No  -> 跳过
       └─ Yes -> READ 0x44
                    ↓
               WAIT rsp_valid
                    ↓
                  下一 bit
                    ↓
             alarm_clear_done
```

