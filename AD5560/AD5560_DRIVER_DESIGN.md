# AD5560 Driver 设计

## 1. 模块定位

`AD5560 Driver` 对应一条 AD5560 SPI BUS，负责本组 16 颗 AD5560 的寄存器事务执行。

上层只需要描述“访问哪颗器件、读写哪个寄存器、写入什么数据”，`AD5560 Driver` 负责完成对应的 AD5560 SPI 事务。

SPI 底层移位、时钟以及单路片选时序由通用 `SPI Master` 实现。`SPI Master` 只输出一根通用 `CS_n`，不知道 AD5560，也不知道本 BUS 上有 16 颗器件。

`AD5560 Driver` 根据 `DEVICE_ID` 将 SPI Master 的 `CS_n` 映射到本组 16 路独立 `SYNC` 中的一路，因此器件选择仍属于 Driver。

`AD5560 Driver` 还负责 AD5560 特有的寄存器帧组织、readback 两帧流程、SPI transaction 之间的等待时间、读回时钟选择以及写事务的 `BUSY` 处理。

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

每次 SPI transaction 只允许选择一颗 AD5560。

为简化第一版设计，可统一采用 **10 MHz SCLK**。

---

## 3. 主要功能

### 3.1 器件选择与 SYNC 映射

上层提供 `DEVICE_ID`。Driver 执行期间不再额外锁存 `DEVICE_ID`，由上层 `Bus Service` 保证从 `drv_start` 发出到 `drv_done` 返回期间，所有 Driver 命令参数保持不变。

Driver 根据当前 `DEVICE_ID` 将 SPI Master 的 `CS_n` 映射为对应 AD5560 的 `SYNC`。

实际 RTL 需保证任何时刻最多只有一路 `SYNC` 为低。

### 3.2 AD5560 寄存器写

上层提供：

```text
RW
DEVICE_ID
REG_ADDR
REG_DATA
```

`AD5560 Driver` 负责组织 AD5560 的 24 bit SPI 写帧，并调用 `SPI Master` 完成一次完整 SPI transaction。

对于写事务，Driver 不能在 SPI 完成的同一时刻立即判断 `BUSY`，而应先经过固定保护时间，再判断器件是否仍处于 BUSY。

对于写事务，不要求必须观察到一次 `BUSY=0`。如果 BUSY 低脉冲较短，在保护时间结束前已经恢复为高，可直接认为器件内部处理已经结束。

`BUSY` 等待需要设置 timeout，避免器件异常导致上层流程永久阻塞。

AD5560 的 DAC x1 写入 BUSY low 最长约 1.5 µs，其他寄存器写入最长约 280 ns，因此正常写事务的 BUSY timeout 应明显大于 1.5 µs，并留有板级和时钟裕量。

写结束已经等待 BUSY 固定时长，且大于 `SYNC↑` 到 SDO high-Z，无需重复等待。

### 3.3 AD5560 寄存器读

上层只发起一次寄存器读请求。

AD5560 readback 由 Driver 内部封装为两次独立 SPI transaction。

依据 AD5560 Rev.F 的 SPI Read Timing，readback 两帧之间只要求满足最小 `SYNC` high time；**读事务两帧之间不等待 BUSY，也不执行写事务的 BUSY 检测流程。**

因此 readback 要求的 `SYNC` high time，本质上就是两次 SPI transaction 之间的间隔。

第 2 帧使用 NOP，避免为了移出 readback 数据而修改其他寄存器。

读后注意 `SYNC` 拉高后，SDO 最迟约 30 ns 回到 high-Z。完成该保护时间后再返回 `drv_done`。

### 3.4 BUSY 处理

每条 BUS 的 16 颗 AD5560 共用一根开漏 `BUSY`，由对应 `AD5560 Driver` 直接检测。

`BUSY` 主要用于写事务以及 RESET / 上电等内部处理状态。Datasheet 的 BUSY Function 明确说明寄存器写会使 BUSY 拉低；readback 时序图不要求在两帧之间等待 BUSY。

为避免在前一笔写操作尚未完成时启动新的访问，**任何新事务开始前仍应先确认共享 `BUSY` 已释放。**

---

## 4. SPI / AD5560 时序边界

依据 AD5560 Rev.F datasheet Table 2，建议第一版按以下方式预留：

| 项目 | Datasheet 要求 | 实现建议 | 归属 |
|---|---:|---:|---|
| `SYNC↓` 到首个 SCLK falling edge | ≥ 10 ns | ≥ 50 ns | SPI Master 的 CS setup |
| 第 24 个 SCLK falling edge 到 `SYNC↑` | ≥ 5 ns | ≥ 50 ns | SPI Master 的 CS hold |
| 普通事务 `SYNC` high time | ≥ 15 ns | ≥ 50 ns | SPI Master / transaction 间隔 |
| 写事务 `SYNC↑` 到 `BUSY↓` | 最大 40 ns | SPI done 后先等待 ≥ 100 ns 再检测 BUSY | AD5560 Driver |
| Readback 两帧之间 `SYNC` high time | ≥ 250 ns | 两次 SPI transaction 间隔 ≥ 500 ns，**不等待 BUSY** | AD5560 Driver |
| `SYNC↑` 到 SDO high-Z | 最大 30 ns | 下一次 SPI transaction 不早于普通 CS high guard | SPI Master / Driver |

上述建议值以逻辑简单和留有裕量为优先，不追求极限 SPI 吞吐率。

---

## 5. 与 Bus Service 的接口

`Bus Service` 与 `AD5560 Driver` 为一对一关系，采用简单的 `start / done` 脉冲接口。

Service 到 Driver：

```text
drv_start              // 单 clk 脉冲
drv_rw
drv_device_id[3:0]
drv_reg_addr[6:0]
drv_wr_data[15:0]
```

Driver 返回：

```text
drv_done               // 单 clk 脉冲
drv_rd_data[15:0]
drv_error
```

接口约束：

- `drv_start` 仅在 Driver 空闲时拉高 1 clk；
- Driver 收到 `drv_start` 后立即开始执行当前输入参数描述的寄存器事务；
- Driver 内部不再重复锁存 `drv_rw / drv_device_id / drv_reg_addr / drv_wr_data`；
- `Bus Service` 必须保证从 `drv_start` 发出开始，到 `drv_done` 返回之前，上述参数保持不变；
- `drv_done` 为单 clk 脉冲，表示本次寄存器事务已经完全结束；
- 读事务在 `drv_done` 有效时，`drv_rd_data` 有效；
- `drv_error` 在 `drv_done` 有效时表示本次事务是否异常。

