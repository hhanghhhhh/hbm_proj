## AD5560

1. 对于上位机不显示 bus，上位机下发 0 - 127，fpga 自己分配 bus + device_id
2. 指令：开始配置某个，开始配置全部（支持 8 条并行配置），开始上电

再开始细节，各模块的接口设计。


CLH/CLL 是用来设置限流 current clamp 的
CPL/CPH 这个是 Comparator（比较器），仅用来告警，不限制电流，告警信号通过 CPOH/CPOL/CPO 指示。
其中，0x2 的 CMP[1:0] 用来设置比较器的来源，可选电压、电流。


### 设计条件

Vref = 2.5V， 放大 5.125 倍，给内部各 DAC 使用，满码值对应 2.5 * 5.125 = 12.8125V。

offset 能把 DAC 的范围进行横移，但是校准系数 c 不行，因为对于 DAC 来说只能输出正值，不能通过 code 值来改变 DAC 输出负压。offset 是个真实电压，可以做差，可以改变输出电压范围。

设置 c 后实际上会吃掉一侧的数字码余量。

ADC 输入电压范围 -2 ~ 12V。

### 1. 电压

输出电压范围： `-1 ~ 11V`

DAC： `V = 12.8125 / 65536 * (codeX2 - offset_code) = Vdac - Voffset`

`Vdac` 输出 `0 ~ 12.8125V`，`Voffset` 是偏置电压，可以把这个范围横移。

对于输出电压，电压采样分压比为 1，DAC 值即为输出值。

`Voffset` 大概选 `1.4V` 左右。（1 ~ 1.8V 可选）

DAC 输出范围为：`-1.4V ~ 11.4125V`，两边各 0.4V 裕量用于校准。

对于 `measout`：

```
Vmin = -Voffset = -1.4V
Vmid = 6.40625 - Voffset = 5.00625V
```
| 电压范围 | measout gain | 进 ADC 电压 |
|---|---|---|
| `-1 ~ 10V` | 1 | -1 ~ 10V |
| `10 ~ 11V` | 0.2 | 2.28 ~ 2.48V (0.2 * (Vdut - Vmin))|

#### 寄存器

| 地址 | 功能 |
|---|---|
| `0x01` | MEASOUT gain |
| `0x08` | FIN DAC |

### 2. 限流

`CLH/CLL` 是用来设置限流 current clamp 的，分别设置正向、负向过流，并触发 `CLALM` 报警。
电流精度大概 10%*FSCR，精度较差。

限流值与 `Voffset` 无关（由于 Vmid，应该内部做差消去 offset 的影响）：

```
I = 12.8125 / 65536 * (codeX2 - 32768) / (Rsense * MIgain)
```

公式中 32768 为固定值，因此，限流固定是正负对称的。也就是 `I * Rsense * MIgain` 范围是 `-6.4 ~ 6.4` 之间。

| 电流挡位 | Rsense | MIgain | I * Rsense * MIgain | Vout (gain = 1) |
|---|---|---|---|---|
| `25mA、2.5mA、250uA、25uA、5uA` | / | 10 | -5 ~ 5V | 0.00625 ~ 10.00625V |
| `0.5A` | 0.5  | 20 | -5 ~ 5V | 0.00625 ~ 10.00625V |
| `1.2A` | 0.2  | 20 | -4.8 ~ 4.8V | 0.20625 ~ 9.80625V |


```
gain = 1：Vout = I * Rsense * MIgain + Vmid
gain = 0.2：Vout = I * Rsense * MIgain * 0.2 + 0.5125 * 2.5

```

`gain = 1` 稍微超量程，无校准裕量，可稍微调小 Voffset。

#### 寄存器

| 地址 | 功能 |
|---|---|
| `0x01` | MI gain |
| `0x02` | 电流挡位、CLEN |
| `0x0D` | CLL DAC |
| `0x10` | CLH DAC |

### 3. 上电时序

使用 ramp 后，slew rate 设置为最快 1V/us 即可。

```
1. 初始状态：Force Amplifier 禁止，DUT 为 High-Z。
2. Ramp 前完成所有静态配置（挡位、限流、以及固定配置）
3. 设置起点和终点：FIN DAC x1 = 0、Ramp End Code = END_CODE
4. 先输出 0 V：SW_INH = 1，HW_INH = 1。（GANG 模式先启动 master）
5. 启动 Ramp：SPI 命令 Write 0x41 = 0xFFFF （逐个启动）
```

#### Ramp 启动延迟

Ramp Enable 后通常需要约：`(2 x Divider + 2)` 个 RCLK 才开始实际更新，如果使用同一个 RCLK，但是不同 device 斜率跨度较大，导致 `Divider` 差别较大，则上电延迟不同。

例如，500k 时钟，则一个 RCLK 2us，Divider = 255 时，延迟 1ms。

#### 寄存器

| 地址 | 功能 |
|---|---|
| `0x08` | FIN DAC x1；Ramp 开始前的当前值就是 Start Code |
| `0x3E` | Ramp End Code，与 FIN x1 属于同一 code 域 |
| `0x3F` | Ramp Step Size，定义 x1 每一步变化多少 |
| `0x40` | RCLK Divider |
| `0x41` | Enable Ramp，写 `0xFFFF` 启动 |
| `0x42` | Interrupt Ramp，写 `0x0000` 中断 |


### 4. OSD\DUTGOND

```
V = 2.5 * code / 65536
```

与 offset DAC 无关，范围 0 ~ 2.5V。

#### 寄存器

| 地址 | 功能 |
|---|---|
| `0x0C` | OSD DAC |
| `0x3D` | DGS DAC |


### 几个上下电控制

SW_INH/HW_INH  = 1 控制 Force Amp 使能，不使能的时候输出高阻。

FINGND = 1 控制 ref 给 0，等价于 FIN DAC = 0 V，相当于控制输出 0V。

PD 控制 Force Amp 的供电（1 - 有电，0 - 没电）。
