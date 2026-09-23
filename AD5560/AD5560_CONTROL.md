# AD5560 控制与上电时序说明

## 1. 文档目的

本文整理 AD5560 在 DUT 供电场景下与输出控制、上下电、电压变化和多器件同步相关的器件机理。

本文属于 **AD5560 器件控制手册说明**，用于描述芯片本身提供的各种控制机制，不限定具体项目必须采用其中哪一种方案。

项目级设计文档应根据实际 DUT 的电源时序、斜率和故障处理要求，从本文描述的机制中选择最终方案，并只保留项目真正采用的控制流程。

本文只描述 AD5560 自身控制相关内容，不讨论其他电源方案。


---

## 3. FIN DAC、SW_INH 与 HW_INH

### 3.1 FIN DAC

`FIN DAC x1` 位于地址 `0x08`，决定 Force Voltage 的目标值。

需要明确：

> 写 FIN DAC 是修改目标电压，不等同于打开或关闭 Force Amplifier。


### 3.4 SW_INH 与 HW_INH 的组合关系

`SW_INH` 与 `HW_INH` 为 AND 关系：


任意一个为 0，Force Amplifier 都被禁止，输出 High-Z。

---

## 4. High-Z 与主动输出 0 V

这是理解 AD5560 上下电和 Ramp 时非常重要的区别。

### 4.1 High-Z

当：

```text
SW_INH = 0 或 HW _INH = 0
```

Force Amplifier 被禁止，DUT 端相当于高阻。


### 4.2 主动输出 0 V

当：

```text
SW_INH = 1
HW_INH = 1
FIN DAC = 0 V 对应 Code
```

Force Amplifier 已经工作，AD5560 会主动把 DUT rail 调节到 0 V 附近。


---

## 5. FIN DAC 的完整数据链路与计算关系

AD5560 的 FIN DAC 不是简单地把 SPI 写入的 16-bit 原码直接送入模拟 DAC。

### 5.1 完整链路

对于 Force Voltage，可以按下面的链路理解：

```text
上位机目标电压
      |
      v
FIN DAC x1 Register (0x08)
      |
      |  Ramp Function 直接修改的也是 x1
      v
Calibration Engine
      |  m: Gain Correction
      |  c: Offset Correction
      v
FIN DAC x2
      |
      v
16-bit Resistor-String DAC
      |
      |  固定模拟增益 = 5.125
      |  VREF 通常 = 5 V
      v
Force DAC 模拟电压
      |
      |  Offset DAC 平移整个输出窗口
      |  DUTGND 提供基准
      v
Force Amplifier
      |
      v
FORCE / SENSE 闭环
      |
      v
DUT
```

其中：

- `x1`：SPI 可写、可读的目标码，也是 Ramp Engine 操作的数字码；
- `m/c`：Gain / Offset Correction 系数；
- `x2`：Calibration Engine 计算后真正加载到 resistor-string DAC 的数据字；
- `x2` 不支持通过 SPI 直接 Readback；
- `5.125` 是芯片内部固定的 DAC amplifier 模拟增益，不是可编程增益；
- `Offset DAC` 与校准寄存器 `c` 是两个不同概念。

### 5.2 VREF 与固定 5.125 增益

AD5560 的 `VREF` 输入允许约 `2 V ~ 5 V`，通常采用 `5 V`。

内部 DAC amplifier 的固定增益为：

```text
G_DAC = 5.125
```

因此当：

```text
VREF = 5 V
```

原始 DAC 模拟跨度为：

```text
5.125 x 5 V = 25.625 V
```

需要注意：

> `25.625 V` 是 DAC 链路包含 overrange 的原始 span，不代表输出一定是 `0 ~ 25.625 V`，也不代表 AD5560 正常应用时定义了 25.625 V 的额定 Force span。

AD5560 标称 Force Voltage span 为约 `25 V`，额外的模拟增益用于给系统 gain/offset correction 留出校准余量。Offset DAC 可以在器件 headroom 允许的范围内上下移动这个电压窗口。


`5.125` 本身固定，不能通过寄存器关闭或修改；有效数字增益由 `m` register 另外控制。

### 5.3 x1 -> x2：Calibration Engine

DAC 数字校准公式为：


```text
x2 = x1 x (m + 1) / 65536 + (c - 32768)
```

其中：

| 参数 | 含义 | 默认值 |
|---|---|---:|
| `x1` | 写入 FIN DAC input register 的 16-bit code | `0x8000` |
| `m` | Gain Correction | `0xFFFF` |
| `c` | Offset Correction | `0x8000` |
| `x2` | Calibration Engine 计算后送入实际 DAC 的 code | 内部值 |

默认：

```text
m = 0xFFFF -> (m + 1) / 65536 = 1
c = 0x8000 -> c - 32768 = 0
```

因此默认情况下：

```text
x2 = x1
```


### 5.4 x2 -> Force 电压

Force DAC 的转换关系为：


```text
VFORCE = (5.125 x VREF / 65536) x (x2 - OFFSET_DAC_CODE)
       + DUTGND
```

这里：

- `x2` 是经过 `m/c` Calibration Engine 后的 FIN DAC code；
- `OFFSET_DAC_CODE` 是独立 Offset DAC 的 code，用于平移 Force/Clamp/Comparator 等 DAC 的工作窗口；
- `DUTGND` 是整个 DUT 电压的参考基准。


### 5.5 c register 与 Offset DAC 的区别

作用位置不同，c 只能改变 code X2 的值，不影响 DAC 的输出范围，offset 影响实际输出范围：

```text
c register
    -> Calibration Engine 内部的数字 offset correction
    -> 直接修正 x1 -> x2

Offset DAC
    -> 独立的 16-bit DAC
    -> 用于整体移动约 25 V 的 Force 输出窗口
```


### 5.6 默认直接更新时序

默认没有启用外部 LOAD 延迟更新时，写入新的 `x1` 后：

```text
Write FIN x1
    |
    v
Calibration Engine 计算 x2
    |
    | BUSY = Low
    v
x2 Ready
    |
    | BUSY -> High
    v
Actual DAC 更新
```

因此“FIN DAC 写入后直接更新”更准确的说法是：

> 在默认直接更新模式下，写 `x1` 会触发 Calibration Engine；计算完成后新的 `x2` 自动更新到实际 DAC，并不是 SPI 帧结束瞬间模拟输出立即变化。

---

## 6. 两种输出变化速度控制方式


### 6.1 Programmable Slew Rate

`DPS Register 2` 地址 `0x03`，`SR[2:0]` 位于 Bit[14:12]。

典型可选 Slew Rate：

| SR | Slew Rate |
|---:|---:|
| 0 | 1 V/us |
| 1 | 0.875 V/us |
| 2 | 0.75 V/us |
| 3 | 0.625 V/us |
| 4 | 0.5 V/us |
| 5 | 0.4375 V/us |
| 6 | 0.35 V/us |
| 7 | 0.313 V/us |

该功能通过改变 Force DAC 输出放大器相关内部补偿，限制模拟输出追踪目标值的速度。

例如：

```text
FIN DAC = 1.1 V
SW_INH = 1
HW_INH = 0
```

随后：

```text
HW_INH: 0 -> 1
```

Force Amplifier 开始向已预设的 1.1 V 目标值变化，输出边沿受 Slew Rate、Current Range、负载电容及环路条件共同影响。

Slew Rate 适合较快的受控电压变化。

### 6.2 Ramp Function 的本质

Ramp Function 的本质是：

> **Ramp Engine 直接在 FIN DAC `x1` code 上做加减；每一步得到新的 `x1` 后，再经过 Calibration Engine 计算新的 `x2`，最后更新实际 DAC。**




相关寄存器：

| 地址 | 功能 |
|---|---|
| `0x08` | FIN DAC x1；Ramp 开始前的当前值就是 Start Code |
| `0x3E` | Ramp End Code，与 FIN x1 属于同一 code 域 |
| `0x3F` | Ramp Step Size，定义 x1 每一步变化多少 |
| `0x40` | RCLK Divider |
| `0x41` | Enable Ramp，写 `0xFFFF` 启动 |
| `0x42` | Interrupt Ramp，写 `0x0000` 中断 |

### 6.3 Ramp Step Size 寄存器

`0x3F` 的 `D6:D0` 定义 Step Size，以 `16 LSB` 为基本单位。

数据手册给出的关系为：

```text
0000000 -> 16 LSB （0 时至少为 1）
0000001 -> 16 LSB
0000010 -> 32 LSB
...
1111111 -> 2032 LSB （127 * 16）
```


这里的 LSB 应理解为 **FIN DAC x1 code 的 LSB**。

设：

```text
start     = 当前 FIN x1
end       = Ramp End Code
step      = Ramp step size
```


Ramp 的方向由当前 FIN `x1` 与 `Ramp End Code` 的大小关系决定。

如果最后剩余的 code 差小于一个完整 Step，最后一步自动缩小，使 FIN x1 恰好到达 End Code。



### 6.6 为什么数据手册写 16 LSB = 6.1 mV

当 `VREF = 5 V` 时，

```text
16 LSB ~= 5 * 5.125 * 16 / 65536  = 6.256 mV
```

但数据手册 Ramp 表使用的 `6.1mV`，因为数据手册使用的 `25 V nominal Force span` 的口径，因此：

```text
16 LSB ~= 25 * 16 / 65536  ~= 6.1 mV
```



本项目使用使用 `2.5 V Vref`，则得到：

```text
16 LSB ~= 2.5 * 5.125 * 16 / 655366  = 3.128 mV
```





### 6.7 RCLK Divider 与理论 Ramp 更新周期

`0x40` 的 `D7:D0` 定义 RCLK Divider：

```text
0   -> /1
1   -> /1
2   -> /2
3   -> /3
...
255 -> /255
```
Ramp 每一步都需要经过 Calibration Engine。数据手册说明 calibration delay 约为 `1.2 us`，并给出 Divider = 1 时外部 RCLK 最大约 `833 kHz`：

```text
1 / 833 kHz ~= 1.2 us
```










则稳态 Ramp step 的更新周期：

```text
T_STEP = D / F_RCLK
```



### 6.8 理论 Ramp 斜率公式

平均数字 Ramp 斜率可以按：

```text
SR = Delta_V_STEP / T_STEP
```





### 6.9 datasheet 的 0.775 V/us 与 833 kHz 说明

数据手册给出：

```text
VREF = 5 V
RCLK = 833 kHz
STEP = 2032 LSB
Divider = 1
Fastest Ramp Rate = 0.775 V/us
```

但如果把表中的 `2032 LSB ~= 775 mV` 直接除以：

```text
1 / 833 kHz ~= 1.2 us
```

得到的算术结果约为：

```text
775 mV / 1.2 us ~= 0.646 V/us
```

ADI EngineerZone 对该问题的答复指出，datasheet 中的 `0.775 V/us` 应理解为器件设计/characterization 给出的能力值，而不是简单按 `Step Voltage x 833 kHz` 推导得到的公式值。

实际 DUT 节点电压还会受到 Force Amplifier slew、负载电容、电流限制、环路稳定性以及线路压降等模拟因素影响。

### 6.10 Ramp 启动延迟

Ramp Enable 后通常需要约：

```text
(2 x Divider + 2) 个 RCLK
```

才开始实际更新，如果不同 device 使用不同 RCLK 需要考虑该延迟，因为 Divider = 255 时延迟还挺大的。


---

## 7. 两类典型电压控制场景

AD5560 的控制可以先按两类场景理解。

### 7.1 场景 A：High-Z / 下电状态 -> 工作电压


#### 方法 A：预设目标 FIN + HW_INH/SW_INH + Slew Rate


适合 Slew Rate 范围本身能够满足 DUT 要求的情况。

#### 方法 B：先进入主动起始电压，再用 Ramp Function


适合需要远慢于 Programmable Slew Rate、并要求斜率由数字 Step/RCLK 明确控制的情况。

需要注意：

> `High-Z -> 主动 0 V` 这一段本身不属于 Ramp Function。


### 7.2 场景 B：已经在线输出 V1 -> V2


#### 方法 A：直接写新的 FIN DAC + Slew Rate


适合普通在线电压调整。

#### 方法 B：Ramp Function


这通常是 Ramp Function 最直接的使用方式，因为 Force Amplifier 已经处于工作状态。

---

## 8. Ramp Function 用于 DUT 上电时的典型顺序

假设目标是从 0 V Ramp 到 `V_TARGET`。

### 8.1 初始安全状态


Force Amplifier 禁止，DUT 为 High-Z。

### 8.2 Ramp 前完成静态配置


### 8.3 设置起点和终点

```text
FIN DAC x1 = START_CODE
Ramp End Code = END_CODE
```

Ramp Start 没有独立寄存器，启动 Ramp 时当前 FIN `x1` 就是 Start Code。


### 8.4 先进入 ZERO_FORCE



```text
SW_INH = 1
HW_INH = 1
FIN DAC = 0 V 对应 x1
```

Force Amplifier 已经接管 DUT，DUT 被主动调节到 Ramp 起始电压。

### 8.5 启动 Ramp


```text
Address = 0x41
Data    = 0xFFFF
```


### 8.6 不应先 Ramp 完再打开 Force Amplifier

如果：

```text
HW_INH = 0
FIN: START -> V_TARGET 完成 Ramp
然后 HW_INH = 1
```

则 DUT 在 Ramp 期间一直 High-Z，最后仍然是从 High-Z 直接接到目标电压，Ramp 没有作用到 DUT。

---

## 9. Ramp 结束、中断与状态判断

### 9.1 Ramp 的结束条件

Ramp 会在以下情况之一发生时退出：

1. FIN x1 到达 Ramp End Code；
2. 控制器写 `0x42 = 0x0000` 执行 Interrupt Ramp；
3. 已使能的 Alarm 触发，使 Ramp 被中断。

被中断时，FIN DAC `x1` 停留在当时已经到达的值，并退出 Ramp Mode。

### 9.2 没有专用 RAMP_DONE 标志

AD5560 没有独立的 RAMP_DONE pin，也没有专门的 Ramp Complete status bit 供 FPGA 轮询。


### 9.3 FPGA 如何确认 Ramp 完成

此可以计算 Ramp 所需步数和预计时间。



如果需要进一步确认，可在预计完成后读取：

```text
FIN DAC x1 (0x08)
```

检查是否已经达到 Ramp End Code。

同时 FPGA 应监视 Alarm；如果 Ramp 期间 Alarm 先发生，应按 Ramp Abort 处理，而不能仅依赖预计结束时间。

---

## 10. Ramp 与硬件触发

Ramp Function 不能由：

- `HW_INH`；
- `CLEN/LOAD`；
- `HW_INH/LOAD`；
- 其他外部硬件引脚；

直接触发。

Ramp 的启动方式是 SPI 命令：

```text
Write 0x41 = 0xFFFF
```


---

## 11. LOAD 的实际作用

### 11.1 LOAD 不是 Power Enable，也不是 Ramp Start

`LOAD` 最主要的用途是：

> 允许控制器先把新的 DAC / Range / Compensation 数据准备好，但暂时不让这些新值作用到实际输出；等 LOAD 条件到来时再统一更新。


### 11.2 LOAD 与 x1/x2 的关系

以 FIN DAC 为例，可以把内部数据路径理解为：

```text
SPI Write
   |
   v
FIN x1 Register
   |
   v
Calibration Engine
   |
   v
new FIN x2 ready
   |
   | 是否立即更新由 LOAD 模式决定
   v
Actual DAC
```

因此：

> LOAD 不是把某个额外“预写寄存器”复制到 FIN x1；FIN x1 在 SPI 写入时已经更新。LOAD 控制的是经过 Calibration Engine 得到的新 `x2` 以及相关受 LOAD 控制的数据，什么时候真正加载到实际工作部分。

### 11.3 System Control 的 LOAD 模式

`System Control Register 0x01` 的 `LOAD[1:0]` 用于选择更新方式。

#### `LOAD = 0`

默认直接更新模式。


不需要外部 LOAD 动作。

#### `LOAD = 1`

`CLEN/LOAD` 引脚被重配置为 LOAD。


该模式下 `CLEN/LOAD` 不再承担原来的硬件 CLEN 功能。

#### `LOAD = 2`

`HW_INH/LOAD` 引脚被重配置为 LOAD。

此时该引脚不再承担硬件 `HW_INH` 功能，因此如果系统依赖 HW_INH 做快速关断，应谨慎使用这种模式。

#### `LOAD = 3`

不占用额外 LOAD 引脚，利用 `BUSY` 的释放实现同步更新。

多颗 AD5560 的 `BUSY` 为 open-drain，可按设计要求 wired-OR。只有当共享 BUSY 恢复 High，表示这一组相关内部计算都完成后，才进行同步更新。

该模式适合多器件同步更新，又希望保留 `CLEN` 和 `HW_INH` 原始功能的情况。


### 11.5 LOAD 的典型使用场景

 LOAD 更适合“同步更新已有工作通道”，而不是承担普通上电时序。

---

## 12. 多颗 AD5560 的控制与同步

### 12.1 HW_INH 同步 Enable

如果多个 AD5560 已经预配置目标 FIN DAC，可以让多个器件共用一根 `HW_INH`，可实现多个 Force Amplifier 的硬件级同时 Enable。


### 12.3 多颗器件的 Ramp 时序

Ramp 没有公共硬件 Start pin。

多个 AD5560 必须分别执行：

```text
Write 0x41 = 0xFFFF
```


### 12.4 多通道在线同步电压变化

如果多个已经在线的通道需要在同一时刻由各自 V1 切换到新的 V2，并且同步精度高于顺序 SPI 写能够提供的水平，则 LOAD 更有价值。


### 12.5 GANG 并联输出

GANG 用于多颗 AD5560 并联提高输出电流。可采用 FV/FV 或 FV/FI；需要均流时优先采用 **Master FV + Slave FI**。

`DPS Register 2` 的 `GANGMODE[10:9]` 与内部开关关系如下：

| GANGMODE | 模式 | SW1 | SW2 | SW5 | SW6 |
|---|---|---|---|---|---|
| `00` | Master FV，电压复制 | b | a | a | OFF |
| `01` | Master FV，电流复制 | b | a | b | OFF |
| `10` | Slave FV | c | c | OFF | ON |
| `11` | Slave FI | c | b | OFF | ON |


FV/FI 的典型连接为：

```text
Master  GANGMODE = 01
MASTER_OUT = Master MI
       |
       v
Slave1  SLAVE_IN   GANGMODE = 11
         MASTER_OUT
       |
       v
Slave2  SLAVE_IN   GANGMODE = 11
         MASTER_OUT
       |
       v
...
```

Slave 的 `SW6 = ON` 用于把前级 GANG reference 继续传到下一颗，**不是重新用本 Slave 的测量电流生成新的参考**。

FV/FI GANG 需满足以下约束：

- Master 与所有 Slave 使用相同 Current Range，并保持 Rsense 及测量链路匹配；
- Master 与 Slave 的 MI Gain 必须一致，否则相同 `SLAVE_IN` 电压不再对应相同电流；
- Slave 的 Current Clamp 必须关闭。若 `CLEN/LOAD` 仍作为 CLEN，实际 Clamp Enable 为软件 `CLEN` 与硬件 CLEN 的 OR，因此应同时保证软件 `CLEN = 0`、CLEN pin = Low；
- Master Clamp 可以保留，但总 GANG 限流值只能近似理解为并联路数乘以 Master 电流，不应作为高精度总电流限制；
- Master SENSE 应 Kelvin 接到实际 DUT 节点；各器件 DUTGND 使用同一 DUT ground reference；
- Slave FI 不直接照搬 Master 的 FV 补偿；进入 Slave FI 后器件会覆盖部分补偿参数，具体见“补偿模式与使用原则”；Master Compensation 按 DUT 负载条件配置；
- GANG reference 链路应尽量短，最后一级 `MASTER_OUT` 可不连接；Master 的 `SLAVE_IN` 不使用；
- `LOAD` 不能同步切换 `GANGMODE`。

进入或退出 GANG 时，正在改变 GANG 配置的 Slave 应保持 High-Z。典型进入顺序为：先关闭 Slave 输出并完成 Range、MI Gain、Clamp、Compensation 配置，再设置 Master=`01`、Slave=`11`，最后使能 Slave；退出时采用相反顺序，必要时先将 Master 输出降到安全电压。

---

## 13. 下电控制

### 13.1 直接禁止输出

直接执行：

```text
HW_INH = 0 或 SW_INH = 0
```

会使 Force Amplifier 进入 High-Z。

此后 DUT rail 的下降过程主要由 DUT 电容、负载、泄放和外围电路决定，并不等于受控 Ramp Down。

### 13.2 受控下降到 0 V 再进入 High-Z

如果需要明确控制下降斜率，可以使用 ramp function，把电压下降到 0 后再断开进入 High-Z。





---

## 14. 补偿模式与使用原则

AD5560 提供 Safe、Auto 和 Manual 三种 Force Amplifier 补偿方式。

### 14.1 模式选择

补偿模式主要由 `Compensation Register 1 (0x04)` 和 `Compensation Register 2 (0x05)` 控制：

| Manual，0x05[15] | SAFEMODE，0x04[7] | 实际模式 |
|---:|---:|---|
| 0 | 0 | Safe Mode |
| 0 | 1 | Auto Compensation |
| 1 | X | Manual Compensation |

因此 Manual 优先级最高；上电 / Reset 后默认先处于 Safe Mode。

### 14.2 Safe Mode

Safe Mode 使用器件内部预设的一组保守补偿参数，主要用于负载条件未知、初始化阶段或状态切换期间优先保证稳定。

Safe Mode 响应较慢，不建议作为正常 DUT 工作时长期固定使用。

### 14.3 Auto Compensation

Auto 模式下，由软件在 `0x04` 中给出 DUT 电容 `CDUT` 和 ESR 范围，器件据此自动选择 gm、CC、CF、RZ、RP 等补偿参数。

Auto 并不会自动测量 DUT 电容和 ESR，因此 DUT 类型或负载条件明显变化时，需要重新配置对应的 CDUT / ESR code。

配置原则：

- 不应高估 CDUT；
- 不应低估 ESR；
- 不确定时优先使用偏保守的配置，允许响应慢一些，不应以稳定性换速度。

Auto 模式下可读取 `0x05`，查看器件最终选择的补偿参数，便于开发阶段表征。

### 14.4 Manual Compensation

Manual 模式下设置 `0x05[15] = 1`，由软件直接设置 gm、RZ、RP、CF、CC 等补偿参数。

适合：

- PCB、Socket、DUT 类型基本固定，并已通过实测完成稳定性和瞬态验证；
- 负载电容在 `0 ~ Cmax` 较大范围内变化，希望使用一套固定、经过验证的保守参数覆盖整个范围。

量产时可以针对不同 DUT / Range 固化不同 Manual Compensation Profile。

### 14.5 推荐使用流程

开发阶段建议按以下流程使用：

```text
上电 / Reset
    ↓
Safe Mode
    ↓
完成 Range、Force 等基础配置
    ↓
根据已知 DUT C / ESR 切换 Auto
    ↓
验证阶跃、Ramp、过冲和负载瞬态
    ↓
必要时读取 0x05 查看 Auto 结果
    ↓
继续使用 Auto
或
固化为经过验证的 Manual Profile
```

补偿参数属于闭环的一部分，正常情况下不建议在 DUT 已处于高电压、大电流工作状态时随意切换 Safe / Auto / Manual。优先在 High-Z 或安全低电压状态完成补偿切换，再进入正常输出或 Ramp。

### 14.6 GANG 模式

FV/FI GANG 时：

- Master 仍工作在 FV，负责公共 DUT 节点的电压闭环，因此 Master Compensation 应按 DUT 电容、ESR 和动态性能要求选择 Auto 或经过验证的 Manual；
- Slave FI 负责跟随 Master 电流，不应简单复制 Master 的 FV 补偿参数；
- 进入 Slave FI 后，器件内部会覆盖部分补偿设置，例如 `CF = 0`、`RZ = 0`，并限制 gm，以满足 FI 跟随环路稳定性；
- 这些 Slave FI 内部 override 不应依赖寄存器 Readback 判断；
- GANG 配置和补偿切换应在 Slave 保持 High-Z 时完成，再将 Slave 接入公共 DUT 节点。

因此可以简单记为：

> Safe 用于未知状态和初始化；Auto 用于已知 C / ESR 的正常优化；Manual 用于已经充分表征后的固定配置；Slave FI 按 GANG FI 的内部补偿规则工作，不照搬 Master FV 参数。

---

## 16. 器件控制约束总结

1. 复位完成后先等待 `BUSY = High`，再开始寄存器配置；

10. 默认 `LOAD = 0` 时，写 FIN x1 后经过 Calibration Engine，新的 x2 在内部处理完成后自动作用到实际 DAC；

13. Programmable Slew Rate 和 Ramp Function 是两种不同的输出变化机制；
14. Ramp Step Size 直接作用于 FIN DAC `x1`，不是作用于 `x2`；
15. Ramp Start Code、End Code 和 Step Size 均属于 `x1` code 域；
16. 每一个新的 Ramp x1 都经过 Calibration Engine 生成 x2，再加载到实际 DAC；
17. `m` 和 `VREF` 会影响实际 Ramp 电压步长和斜率；`c`、Offset DAC、DUTGND 不影响相邻 Ramp Step 的电压差；

21. AD5560 没有专用 `RAMP_DONE` 标志，FPGA 可依据已知参数计时，并在需要时读回 FIN x1 确认是否达到 End Code；
22. Ramp 期间 Alarm 可以导致 Ramp 中断；

---

## 17. 参考资料

- Analog Devices, **AD5560 Rev.F Data Sheet**: https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf
- Analog Devices EngineerZone, **Ramp control of AD5560**：关于 `833 kHz / 2032 LSB / 0.775 V/us` 的计算讨论。
