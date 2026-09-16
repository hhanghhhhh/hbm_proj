# AD5560 Driver 设计

## 1. 模块定位

`AD5560 Driver` 对应一条 AD5560 SPI BUS，负责本组 16 颗 AD5560 的寄存器事务执行。

上层只需要描述“访问哪颗器件、读写哪个寄存器、写入什么数据”，`AD5560 Driver` 负责完成对应的 AD5560 SPI 事务。

SPI 底层移位、时钟以及单路片选时序由通用 `SPI Master` 实现。`SPI Master` 只输出一根通用 `CS_n`，不知道 AD5560，也不知道本 BUS 上有 16 颗器件。

`AD5560 Driver` 根据 `DEVICE_ID` 将 SPI Master 的 `CS_n` 映射到本组 16 路独立 `SYNC` 中的一路，因此器件选择仍属于 Driver。

`AD5560 Driver` 还负责 AD5560 特有的寄存器帧组织、readback 两帧流程、SPI transaction 之间的等待时间、读回时钟选择以及 `BUSY` 处理。

`AD5560 Driver` 不负责配置表管理、上下电时序调度、BUS 选择或后台遥测轮询。

---

## 2. 每个 AD5560 Driver 对应的硬件资源

每个实例固定对应一条 SPI BUS：

```text
AD5560 Driver n
├─ 16 颗 AD5560
├─ 16 路独立 SYNC
├─ 1 路共享 BUSY
└─ 1 个 SPI Master
      ├─ SCLK
      ├─ MOSI
      ├─ MISO
      └─ CS_n
```

Driver 根据当前 `DEVICE_ID` 选择一颗 AD5560，并将 SPI Master 输出的单路 `CS_n` 接到对应 `SYNC`：

```text
SPI Master CS_n
      ↓
AD5560 Driver DEVICE_ID 选择
      ↓
SYNC[0..15] 中仅一路跟随 CS_n
其余 SYNC 保持高电平
```

每次 SPI transaction 只允许选择一颗 AD5560。

---

## 3. 主要功能

### 3.1 器件选择与 SYNC 映射

上层提供 `DEVICE_ID`，Driver 在本次事务开始前锁存目标器件编号。

SPI Master 只产生通用单路 `CS_n`：

```text
CS_n 拉低
    ↓
完成 SPI 移位
    ↓
CS_n 拉高
```

Driver 根据锁存的 `DEVICE_ID` 将该 `CS_n` 映射为对应 AD5560 的 `SYNC`。

概念上可理解为：

```verilog
SYNC[0..15] = 全部保持 1
SYNC[device_id] = spi_cs_n
```

实际 RTL 需保证任何时刻最多只有一路 `SYNC` 为低。

### 3.2 AD5560 寄存器写

上层提供：

```text
DEVICE_ID
REG_ADDR
REG_DATA
```

`AD5560 Driver` 负责组织 AD5560 的 24 bit SPI 写帧，并调用 `SPI Master` 完成一次完整 SPI transaction。

### 3.3 AD5560 寄存器读

上层只发起一次寄存器读请求。

AD5560 readback 由 Driver 内部封装为两次独立 SPI transaction：

```text
第 1 次 SPI：发送 Read Request
    ↓
等待 readback 最小事务间隔
    ↓
第 2 次 SPI：发送 NOP，同时从 SDO 接收返回数据
    ↓
向上层返回 REG_DATA
```

两次 SPI transaction 均使用同一个 `DEVICE_ID`。SPI Master 每次 transaction 自己产生一轮 `CS_n`，Driver 将该 `CS_n` 映射到同一路 `SYNC`。

因此 readback 要求的 `SYNC` high time，本质上就是两次 SPI transaction 之间的间隔。

第 2 帧使用 NOP，避免为了移出 readback 数据而修改其他寄存器。

### 3.4 BUSY 处理

每条 BUS 的 16 颗 AD5560 共用一根开漏 `BUSY`，由对应 `AD5560 Driver` 直接检测。

新事务开始前必须确认 `BUSY` 已释放。

SPI transaction 完成后，SPI Master 已经将其通用 `CS_n` 拉高，因此 Driver 映射出的目标 `SYNC` 也已拉高。Driver 不能在 SPI 完成的同一时刻立即判断 `BUSY`，而应先经过固定保护时间，再判断器件是否仍处于 BUSY。

基本流程：

```text
接收寄存器事务
    ↓
确认 BUSY 已释放
    ↓
锁存 DEVICE_ID
    ↓
调用 SPI Master 执行 transaction
    ↓
SPI Master 拉高 CS_n
Driver 对应 SYNC 同步拉高
    ↓
固定 BUSY 检测保护时间
    ↓
BUSY 已高：事务完成
BUSY 为低：继续等待 BUSY 拉高
    ↓
返回事务完成
```

这里要求 SPI Master 的 `done` 表示：**本次 SPI transaction 已完全结束，并且通用 `CS_n` 已经拉高。**

不要求必须观察到一次 `BUSY=0`。如果 BUSY 低脉冲较短，在保护时间结束前已经恢复为高，可直接认为器件内部处理已经结束。

`BUSY` 等待需要设置 timeout，避免器件异常导致上层流程永久阻塞。

---

## 4. SPI / AD5560 时序边界

单次 SPI transaction 内的 SCLK、MOSI/MISO 和通用 `CS_n` 时序由 `SPI Master` 保证；Driver 负责把 `CS_n` 映射为目标器件 `SYNC`，并负责 AD5560 特有的 transaction 间等待与 BUSY 检测等待。

依据 AD5560 Rev.F datasheet Table 2，建议第一版按以下方式预留：

| 项目 | Datasheet 要求 | 实现建议 | 归属 |
|---|---:|---:|---|
| `SYNC↓` 到首个 SCLK falling edge | ≥ 10 ns | ≥ 50 ns | SPI Master 的 CS setup |
| 第 24 个 SCLK falling edge 到 `SYNC↑` | ≥ 5 ns | ≥ 50 ns | SPI Master 的 CS hold |
| 普通事务 `SYNC` high time | ≥ 15 ns | ≥ 50 ns | SPI Master / transaction 间隔 |
| `SYNC↑` 到 `BUSY↓` | 最大 40 ns | SPI done 后先等待 ≥ 100 ns 再检测 BUSY | AD5560 Driver |
| Readback 两帧之间 `SYNC` high time | ≥ 250 ns | 两次 SPI transaction 间隔 ≥ 500 ns | AD5560 Driver |
| `SYNC↑` 到 SDO high-Z | 最大 30 ns | 下一次 SPI transaction 不早于普通 CS high guard | SPI Master / Driver |

上述建议值以逻辑简单和留有裕量为优先，不追求极限 SPI 吞吐率。

### 4.1 SPI Master 与 SYNC 的职责边界

`SPI Master` 是通用模块，仅提供一根 `CS_n`，不直接输出 16 路 AD5560 `SYNC`，也不接收 `DEVICE_ID`。

SPI Master 至少需要支持：

```text
发送数据
传输长度
SPI 时钟配置
start / valid
ready / done
接收数据
CS_n
```

一次 transaction 内 SPI Master 完成：

```text
CS_n 拉低
→ SPI 移位
→ 保持必要 CS hold time
→ CS_n 拉高
→ done
```

Driver 负责：

```text
DEVICE_ID 锁存
→ 将 spi_cs_n 映射到对应 SYNC
→ 其余 SYNC 保持高
```

因此 Driver 可以把 `spi_done` 作为目标 `SYNC↑` 已发生的时间基准。

### 4.2 BUSY 检测保护时间

AD5560 在 `SYNC` 拉高、完成一笔写事务后，`BUSY` 不一定立即拉低。Datasheet 给出的最坏条件为 `SYNC↑` 后最多约 40 ns 才出现 `BUSY↓`。

因此禁止以下实现：

```text
spi_done / SYNC↑
下一拍立即发现 BUSY=1
→ 判定事务完成
```

Driver 应先等待固定保护时间，例如 **100 ns**，再读取 `BUSY`：

```text
spi_done
    ↓
等待 100 ns
    ↓
BUSY = 0 → 等待 BUSY 回到 1
BUSY = 1 → 当前事务完成
```

AD5560 的 DAC x1 写入 BUSY low 最长约 1.5 µs，其他寄存器写入最长约 280 ns，因此正常寄存器事务的 BUSY timeout 应明显大于 1.5 µs，并留有板级和时钟裕量。

### 4.3 Readback 两次 SPI transaction 间隔

Readback 模式要求两帧之间的 `SYNC` high time 至少为 **250 ns**。

因为目标 `SYNC` 只是 SPI Master `CS_n` 经 Driver 选择后的映射，所以 Driver 只需要控制两次 SPI transaction 的启动间隔。

第一版按 **≥ 500 ns** 处理：

```text
第 1 次 SPI transaction done
spi_cs_n 已拉高
对应目标 SYNC 也已拉高
    ↓
等待 ≥ 500 ns
    ↓
启动第 2 次 SPI transaction
spi_cs_n 再次拉低
Driver 将其映射到同一路 SYNC
```

因此不需要在 Driver 中额外产生 `SYNC` 波形，只需要完成选择映射和 transaction 间隔控制。

### 4.4 Readback SCLK

AD5560 的 SDO 驱动较弱，readback 时不能直接按最高写入 SCLK 工作。Datasheet 给出的典型上限为：

```text
DVCC = 2.3 ~ 2.7 V：Readback SCLK ≤ 12 MHz
DVCC = 2.7 ~ 3.3 V：Readback SCLK ≤ 15 MHz
DVCC = 4.5 ~ 5.5 V：Readback SCLK ≤ 20 MHz
```

为简化第一版设计，可统一采用 **10 MHz readback SCLK**。写事务仍可使用独立的正常 SPI 时钟配置。

通用 `SPI Master` 提供可配置时钟能力，具体在读事务中选择较低 SCLK 的策略由 `AD5560 Driver` 决定。

### 4.5 器件切换

`SYNC` 拉高后，SDO 最迟约 30 ns 回到 high-Z。

由于同一 BUS 上 16 颗 AD5560 共用 SDO，Driver 在切换 `DEVICE_ID` 前必须保证上一笔 SPI transaction 已结束，并满足最小 transaction 间隔。

只要：

```text
SPI Master 保证单路 CS_n 的 setup / hold / high time
Driver 保证任意时刻仅一路 SYNC 跟随 CS_n
Driver 在下一笔 transaction 前才允许改变 DEVICE_ID
```

即可避免两个 AD5560 的 SDO 同时驱动共享总线。

---

## 5. 初步接口

`Bus Service` 到 `AD5560 Driver` 的事务接口暂按以下信息组织：

```text
cmd_valid
cmd_ready
cmd_rw
cmd_device_id[3:0]
cmd_reg_addr[6:0]
cmd_wr_data[15:0]
```

返回接口暂按：

```text
rsp_valid
rsp_rd_data[15:0]
rsp_error
```

其中：

- `cmd_rw` 区分寄存器读 / 写；
- 写操作使用 `cmd_wr_data`；
- 读操作完成后通过 `rsp_rd_data` 返回结果；
- `rsp_error` 用于返回 BUSY timeout 等事务异常。

当：

```text
cmd_valid && cmd_ready
```

同时为 1 时，本次事务完成握手，Driver 锁存命令参数并开始执行。握手后上层不需要继续保持本条命令。

`rsp_valid` 表示已经接受的寄存器事务真正执行完成。

---

## 6. 与 Bus Service 的关系

每条 BUS 设置一个 `Bus Service`，`AD5560 Driver` 作为该 Service 的下层寄存器访问执行器。

```text
Bus Service
├─ 接收前台寄存器事务
├─ 空闲时发起后台遥测事务
├─ 维护本 BUS Telemetry RAM
│
└─ AD5560 Driver
      ├─ DEVICE_ID → SYNC 选择
      ├─ BUSY / readback 控制
      └─ SPI Master
            └─ 通用 CS_n
```

`Bus Service` 决定“下一笔执行什么事务”，`AD5560 Driver` 负责“把这一笔 AD5560 寄存器事务执行完成”，`SPI Master` 只负责单次通用 SPI transaction。

前台任务优先于后台遥测。Driver 忙时 Service 不再向其提交新事务；Driver 完成后 Service 再决定下一笔任务来源。

---

## 7. 多 BUS 选择与并行工作

BUS 选择不在 `AD5560 Driver` 内实现。8 个 `Bus Service` 在顶层通过 `generate` 循环例化，每个实例具有固定 `BUS_ID`。

典型选择逻辑：

```verilog
genvar bus_index;
generate
    for (bus_index = 0; bus_index < BUS_COUNT;
         bus_index = bus_index + 1) begin : g_ad5560_bus

        localparam [2:0] BUS_ID = bus_index;
        wire bus_selected;

        assign bus_selected = (bus_sel == BUS_ID);
        assign service_cmd_valid[bus_index] = cmd_valid && bus_selected;

        ...
    end
endgenerate
```

目标 BUS 的 `ready` 按 `bus_sel` 选择后回送给上层：

```verilog
assign selected_ready = service_ready[bus_sel];
```

对于 `Power Sequence Engine`，当前记录与目标 `Bus Service` 完成 `valid / ready` 握手后即可继续读取下一条记录，不等待本条事务对应的 Driver `rsp_valid`。

因此：

```text
不同 BUS：事务可以重叠执行
同一 BUS：通过本 BUS Service / Driver 自动串行
```

例如 BUS0 已经接受一条事务并进入工作状态后，下一条记录如果目标为 BUS3，只要 BUS3 Service 为 ready，就可以立即完成握手并启动 BUS3。这样多个 SPI BUS 可以同时处于工作状态，而上层仍保持单路 `bus_sel + valid / ready` 接口。
