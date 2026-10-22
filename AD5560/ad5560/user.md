## AD5560

### 代码待做

1. ADC 代码移植过来，增加给上位机回传数据的相关协议。不同 device 选择 MI\MV 的时候 gain 设置不一样，这个存在哪里？
2. 在线升级

### CPO 告警

CLH/CLL 是用来设置限流 current clamp 的
CPL/CPH 这个是 Comparator（比较器），仅用来告警，不限制电流，告警信号通过 CPOH/CPOL/CPO 指示。
其中，0x2 的 CMP[1:0] 用来设置比较器的来源，可选电压、电流。

### 设计条件

Vref = 3V， 放大 5.125 倍，给内部各 DAC 使用，满码值对应 3 * 5.125 = 15.375V。

ADC 输入电压范围 -5 ~ 12V。（运放供电 -5 ~ 15，ADC ref 12V）？ 这里 ADC ref 暂未确定

### offset 与校准 c 的区别

offset 能把 DAC 的范围进行横移，但是校准系数 c 不行，因为对于 DAC 来说只能输出正值，不能通过 code 值来改变 DAC 输出负压。offset 是个真实电压，可以做差，可以改变输出电压范围。

设置 c 后实际上会吃掉一侧的数字码余量。

### 1. 电压

输出电压范围： `-1 ~ 13V`

DAC： `V = 15.375 / 65536 * (codeX2 - offset_code) = Vdac - Voffset`

`Vdac` 输出 `0 ~ 15.375V`，`Voffset` 是偏置电压，可以把这个范围横移。

对于输出电压，电压采样分压比为 1，DAC 值即为输出值。

`Voffset` 大概选 `1.6875V` 左右。（1 ~ 2.375V 可选）

DAC 输出范围为：`-1.6875V ~ 13.6875V`，两边各 0.6875V 裕量用于校准。

对于 `measout`：

```
Vmin = -Voffset = -1.6875V
Vmid = 7.6875 - Voffset = 6V
```
| 电压范围 | measout gain | 进 ADC 电压 |
|---|---|---|
| `-1 ~ 10V` | 1 | -1 ~ 10V |
| `10 ~ 13V` | 0.2 | 2.3375 ~ 2.9375V (0.2 * (Vdut - Vmin))|

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
I = 15.375 / 65536 * (codeX2 - 32768) / (Rsense * MIgain)
```

公式中 32768 为固定值，因此，限流固定是正负对称的。也就是 `I * Rsense * MIgain` 范围是 `-7.5875 ~ 7.6875` 之间。

| 电流挡位 | Rsense | MIgain | I * Rsense * MIgain | Vout (gain = 1) |
|---|---|---|---|---|
| `25mA、2.5mA、250uA、25uA、5uA` | / | 10 | -5 ~ 5V | 1 ~ 11V |
| `0.5A` | 0.5  | 20 | -5 ~ 5V | 1 ~ 11V |
| `1.2A` | 0.2  | 20 | -4.8 ~ 4.8V | 1.2 ~ 10.8V |


```
gain = 1：Vout = I * Rsense * MIgain + Vmid
gain = 0.2：Vout = I * Rsense * MIgain * 0.2 + 0.5125 * 2.5
```

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

#### Ramp 斜率计算与 S/D 选择

取 `VREF = 3V`、`m = 0xFFFF`（数字增益为 1），每 16 LSB 的电压步长为：

```text
V_STEP0 = VREF * 5.125 * 16 / 65536 = 3.753662 mV
SR(mV/us) = V_STEP0 * f_RCLK(MHz) * S / D
```

其中 `S = 1~127`（Ramp Step Size，每级为 16 LSB），`D = 1~255`（RCLK Divider；寄存器 0、1 均表示 ÷1）。若修改 FIN DAC 校准系数 `m`，上述电压步长还须乘以 `(m+1)/65536`。

目标斜率范围 `0.01~20 mV/us`，由 `S_min=1、D_max=255` 和 `S_max=127、D_min=1` 得到时钟约束：

```text
f_RCLK <= 0.01 * 255 / 3.753662 = 0.67934 MHz （覆盖最低斜率）
f_RCLK >= 20 / (3.753662 * 127) = 0.04195 MHz （覆盖最高斜率）
即：41.95 kHz <= f_RCLK <= 679.34 kHz
```

**建议固定 `f_RCLK = 100 MHz / 150 = 0.666667 MHz`**：便于 FPGA 分频生成，接近允许上限且留有余量；此时最低可达斜率约 `0.009814 mV/us`，可以覆盖所需范围。计算式变为：

```text
SR(mV/us) = 2.502441 * S / D
D_ideal = 2.502441 * S / SR_target
```

**S/D 选取原则**：从 `S=1` 逐级尝试；每个 S 根据 `D_ideal` 比较附近整数 D（限制 1~255），计算实际 SR 及相对误差；**先满足误差要求（如 <= 1%），再优先选较小 S**，以减小每次电压阶梯。若没有组合满足误差阈值，则采用全局误差最小的组合并报告误差。FPGA 只需使用上位机计算出的 S/D 配置寄存器。

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
