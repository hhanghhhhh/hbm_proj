# AD4114 采样管理模块

## 1. 文件与定位

- RTL：`rtl/samp/ad4114_sample_manager.v`（新增）
- 依赖：`rtl/spi_master_generic.v`（原文件不修改）
- 编码：Verilog-2001，遵循 `VERILOG_CODING_GUIDELINES.md`。
- 此版是独立模块，**未接入 top、System Controller 或 AD5560 命令路由**。

一个采样管理模块共用一组 SCLK/MOSI/MISO，通过 `o_spi_cs_n[MAX_ADC-1:0]` 独立片选 AD4114。默认 `MAX_ADC=20`，`i_adc_enable_mask` 在 `i_start` 时锁存；可适应每板 2/4 颗 ADC，实际布线与 FPGA IO 必须预留片选。各 AD4114 固定 8 路差分：CH0=VIN0/VIN1，依次至 CH7=VIN14/VIN15。

## 2. 数字滤波与刷新时间

AD4114 有 **Sinc5+Sinc1（适合多通道）**、Sinc3（低速单通道噪声性能较好，但切换建立慢）和 **增强型 50/60 Hz 抑制** 三类。普通 Sinc5+Sinc1 在 49.68 SPS 档的陷波频率是 50 Hz、建立时间约 20.13 ms；增强型还可同时抑制 50/60 Hz 及其 ±1 Hz 偏移，但需要更长时间。**20 SPS 不等于 20 ms**。

| 方式 | 速率/配置值（FILTCON0） | 单通道建立时间 | 主要用途 |
| --- | --- | --- | --- |
| 普通 Sinc5+Sinc1 | 59.52 SPS / `0x050F` | 16.80 ms | 约 60 Hz 陷波 |
| **普通 Sinc5+Sinc1（首版）** | **49.68 SPS / `0x0510`** | **20.13 ms** | **50 Hz 陷波，兼顾刷新速度** |
| 普通 Sinc5+Sinc1 | 20.01 SPS / `0x0511` | 49.98 ms | 更低噪声，陷波约 20.06 Hz |
| 增强型 50/60 Hz | 27.27 SPS / `0x0A11` | 36.67 ms | 两种工频 ±1 Hz，47 dB 抑制 |
| 增强型 50/60 Hz | 25 SPS / `0x0B11` | 40.00 ms | 两种工频 ±1 Hz，62 dB 抑制 |
| 增强型 50/60 Hz | 20 SPS / `0x0D11` | 50.00 ms | 两种工频 ±1 Hz，85 dB 抑制 |
| 增强型 50/60 Hz | 16.667 SPS / `0x0E11` | 60.00 ms | 两种工频 ±1 Hz，90 dB 抑制 |

数值按 AD4114 Rev.A Table 16 / Table 18、标称内部时钟列出。普通滤波的陷波较窄，不能将“50 Hz 陷波”理解为“50 Hz ±1 Hz 同等抑制”。8 路差分扫描时，单颗 ADC 一轮约 `8 × 单通道建立时间`；首版约 **161 ms/轮**。MV/MI 轮换和 `skip_cnt` 还会延长相同模式的有效刷新间隔。

### 2.1 后续如何修改

各通道均使用 Setup0/Filter0。修改 `rtl/samp/ad4114_sample_manager.v` 中 `ST_INIT_SEND` 状态的 `INIT_FILTER` 分支：

```verilog
// 地址 0x28 = FILTCON0，当前普通 Sinc5+Sinc1 / 49.68 SPS / 50Hz 陷波
spi_tx <= {40'd0, 8'h28, 16'h0510};
```

需要其他档位时将 `16'h0510` 替换成上表的值并重新初始化 ADC 即可。位域：`[11] ENHFILTEN`（0 普通 / 1 增强）；`[10:8] ENHFILT`（增强档位）；`[6:5] ORDER`（00 Sinc5+Sinc1，11 Sinc3）；`[4:0] ODR`（普通模式的输出速率）。`0x0510` 保留 ENHFILT 默认选择值 101，但因 `ENHFILTEN=0` 不起作用；实际 ODR 由 `0x10` 决定。Sinc3 的多通道建立时间与映射规则不同，不能直接套用上表时间。

运行时如直接写 Filter 配置寄存器，**ADC 会中断当前转换并从扫描序列的第一个通道重新开始**；当前 RTL 仅在初始化写一次，没有动态切换滤波的接口。

其他初始化设置不变：Setup0 = `0x1F20`（双极性、缓冲、内部参考）；Interface = `0x0140`（DATA_STAT=1、CRC=0、CONTREAD=0）；ADC Mode = `0x8000`（连续转换、内部时钟）。模拟前端配置仍需上板核实。

## 3. 初始化和采样行为

`i_start`：锁存使能 Mask 与 `skip_cnt`、清除本模块状态，从 ADC0 起按 Mask 逐颗软件复位（64 个 1）、等待 500us、读取 ID、配置 16 个 Channel 寄存器（仅 0~7 开启）、Setup0、Filter0、Interface、ADC Mode。ID 非 `0x30D?` 的器件置 `o_init_error` 并跳过，其余正常工作。完成后 `o_init_done=1`。

**状态机简化**：没有公共的 `ST_CS_LOW/ST_SEND/ST_WAIT/ST_CS_HIGH` 和 `op`。`ST_PICK` 直接发起复位 SPI，`ST_RESET_DELAY` 等待该帧结束并完成 500us 延时、随后发起 ID 读取，`ST_ID_CHECK` 等待读回并校验；`ST_INIT_SEND` 按 `init_step` 准备配置并发起 SPI，`ST_INIT_NEXT` 等待本次写入结束并推进配置步骤；`ST_READY` 在 RDY 有效时发起数据读取，`ST_PROCESS` 等待该帧结束并直接处理 `spi_rx`。每个发起状态只发送一笔请求，下一业务状态清除 `spi_req`、等待 `spi_rx_valid`，完成后释放 CS。无额外 SPI 子状态机。

连续轮询时，依次选中已使能的 ADC；拉低 CS 后等待约 50 ns，再检查 DOUT/RDY，低电平即读 `0x44` + 24bit DATA + 8bit STATUS（40bit 帧）；高电平则跳到下一颗。使用 STATUS 的 CH 编号定位通道，检查其错误位后处理。没有 CRC。所有有效转换均自动产生；不依赖上位机逐次发读命令。

**CS 时序**：SPI 发送前和 `rx_valid` 后不另加 `CS_GUARD`，使用 `spi_master_generic` 自身的 SCK 启动/结束时序；仅检查 DOUT/RDY 前保留 `RDY_SETUP_CYCLES`。按当前约定，切换到不同 ADC 的 CS 时不增加专门的释放间隔，须在上板时确认共享 MISO 没有驱动争用。

`o_sample_valid` 是一拍脉冲，与 `o_sample_adc_id[7:0]`、`o_sample_channel[2:0]`、`o_sample_data[23:0]` 同拍有效。RAM 地址可由 `adc_id*8+channel` 计算。外部自行判断 MV/MI 并分别保存 24-bit 原始码；错误数据和跳过的数据不产生有效脉冲。

## 4. skip 与外部 MV/MI 切换

本模块**不保存 MV/MI 状态，也不控制 AD5560**。每颗 ADC 的 8 个通道各有一个 `skip_left` 计数器；`i_skip_cnt` 由外部固定给定（通常 `8'd0`，调试可改为 `8'd1`），只在 `i_start` 时锁存为 `skip_cfg`，运行期间不会动态调整。

对于每一个 ADC 通道：STATUS 无错误时，若 `skip_left > 0`，则丢弃该点并减 1；否则输出一次 `o_sample_valid`，并重新加载 `skip_left = skip_cfg`。例如：
- `skip_cnt=0`：每个该通道的正常结果都输出；
- `skip_cnt=1`：输出一个，丢弃下一个，再输出一个；
- `skip_cnt=2`：输出一个，丢弃两个，再输出一个。

**外部收到 `o_sample_valid` 后**，用同拍 `ADC_ID/CH/DATA` 判断该 AD5560 当前是 MV 还是 MI、写入对应 RAM，并触发切换到另一个 MEASOUT 模式。本模块不再输出 `o_sample_mode` 和任何 `o_me_*` 信号，也不等待写寄存器的握手或完成；这使 ADC 轮询不被 AD5560 SPI 写入阻塞。

外部需要维护 `(ADC_ID,CH) -> (AD5560 BUS_ID, DEVICE_ID)` 的映射和 MV/MI 当前状态，确保每次切换命令最终得到执行。写 AD5560 0x02 时，应基于最新 shadow 只更新 ME[8:5]，不可覆盖同寄存器其他功能位。正常采样时 AD5560 切换必须赶在该通道下一次需要转换前完成；在配置、上下电、Alarm/Fault 等无法保障命令执行的阶段，应停止采样或暂停切换并丢弃无法确认模式的数据。

**关键约定**：本模块的 skip 只按 ADC 的通道结果计数，不了解外部切换是否成功或何时完成。若切换命令被丢弃或显著延迟，`skip_cnt` 本身无法保证 MV/MI 结果归属正确。

## 5. 第一版的限制与后续验证

1. 当前只负责 ADC 初始化与连续轮询；`o_sample_valid` 由 ADC 数据驱动，外部自行处理对应 AD5560 的 MEASOUT 切换。两者**没有握手/完成确认**，外部须保证切换能够及时执行。
2. `i_start` 仅在 IDLE 接受，并锁存使能 Mask 和固定 `skip_cnt`；`i_stop` 在安全空闲点生效，正在执行的 SPI 帧不会被中途打断。
3. 外部必须保证初始 MV/MI 状态以及 AD5560 0x02 shadow 一致；若发生 Alarm/Fault、上下电或 AD5560 写入故障，不应继续把未经确认的测量数据当作有效 MV/MI。
4. 当前没有 ADC 连续采样“漏点”上报、外部 ME 切换超时检测或通道采样完成标记；CRC 故意关闭。
5. 已做 RTL 编译检查，未进行 ADC 模型功能仿真或上板测试。重点验证 AD4114 复位/ID、40-bit DATA_STAT 帧、SPI Mode3 边沿、STATUS 错误位、滤波速率、skip=0/1 与外部 MV/MI 切换的配合，以及跨板共享 SPI 的电气负载。

官方参考：[AD4114 Datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/ad4114.pdf)（Filter、Enhanced 50/60 Hz Rejection、Serial Interface、Registers）。
