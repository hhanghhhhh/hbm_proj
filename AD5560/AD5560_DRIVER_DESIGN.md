# AD5560 Driver 设计

## 1. 模块定位

`AD5560 Driver` 对应一条 AD5560 SPI BUS，负责本组 16 颗 AD5560 的寄存器事务执行。

上层只需要描述“访问哪颗器件、读写哪个寄存器、写入什么数据”，`AD5560 Driver` 负责完成对应的 AD5560 SPI 事务。

SPI 底层移位、时钟以及片选时序由通用 `SPI Master` 实现。对 AD5560 而言，`SYNC` 就是 SPI `CS_n`，因此 Driver 不再单独产生或控制 `SYNC`。

`AD5560 Driver` 负责 AD5560 特有的寄存器帧组织、readback 两帧流程、SPI 事务之间的等待时间、读回时钟选择以及 `BUSY` 处理。

`AD5560 Driver` 不负责配置表管理、上下电时序调度、BUS 选择或后台遥测轮询。

---

## 2. 每个 AD5560 Driver 对应的硬件资源

每个实例固定对应一条 SPI BUS：

```text
AD5560 Driver n
├─ 16 颗 AD5560
├─ 1 路共享 BUSY
└─ 1 个 SPI Master
      ├─ SPI BUS n
      └─ 16 路 CS_n / SYNC
```

Driver 向 SPI Master 提供目标 `DEVICE_ID`，SPI Master 根据器件编号选择对应 `CS_n / SYNC`。

每次 SPI transaction 只允许选择一颗 AD5560。

---

## 3. 主要功能

### 3.1 器件选择

上层提供 `DEVICE_ID`，Driver 将目标器件编号传给 SPI Master。

SPI Master 负责：

```text
选择对应 CS_n / SYNC
    ↓
拉低 CS_n
    ↓
完成 SPI 移位
    ↓
拉高 CS_n
```

Driver 不直接操作 16 路 `SYNC`。

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

每次 SPI transaction 内的 `SYNC / CS_n` 拉低、拉高均由 SPI Master 自动完成。

因此 readback 要求的 `SYNC` high time，本质上就是两次 SPI transaction 之间的间隔。

第 2 帧使用 NOP，避免为了移出 readback 数据而修改其他寄存器。

### 3.4 BUSY 处理

每条 BUS 的 16 颗 AD5560 共用一根开漏 `BUSY`，由对应 `AD5560 Driver` 直接检测。

新事务开始前必须确认 `BUSY` 已释放。

SPI transaction 完成后，SPI Master 已经将当前器件的 `CS_n / SYNC` 拉高。Driver 不能在 SPI 完成的同一时刻立即判断 `BUSY`，而应先经过固定保护时间，再判断器件是否仍处于 BUSY。

基本流程：

```text
接收寄存器事务
    ↓
确认 BUSY 已释放
    ↓
调用 SPI Master 执行 transaction
    ↓
SPI Master 完成移位并释放 CS_n / SYNC
    ↓
固定 BUSY 检测保护时间
    ↓
BUSY 已高：事务完成
BUSY 为低：继续等待 BUSY 拉高
    ↓
返回事务完成
```

这里要求 SPI Master 的 `done` 表示：**本次 SPI transaction 已完全结束，并且 `CS_n / SYNC` 已经拉高。**

不要求必须观察到一次 `BUSY=0`。如果 BUSY 低脉冲较短，在保护时间结束前已经恢复为高，可直接认为器件内部处理已经结束。

`BUSY` 等待需要设置 timeout，避免器件异常导致上层流程永久阻塞。

---

## 4. SPI / AD5560 时序边界

`SYNC` 作为 SPI `CS_n` 后，单次 SPI transaction 内的片选时序统一由 `SPI Master` 保证；Driver 只负责 AD5560 特有的 transaction 之间等待以及 transaction 完成后的 BUSY 检测等待。

依据 AD5560 Rev.F datasheet Table 2，建议第一版按以下方式预留：

| 项目 | Datasheet 要求 | 实现建议 | 归属 |
|---|---:|---:|---|
| `SYNC↓` 到首个 SCLK falling edge | ≥ 10 ns | ≥ 50 ns | SPI Master |
| 第 24 个 SCLK falling edge 到 `SYNC↑` | ≥ 5 ns | ≥ 50 ns | SPI Master |
| 普通事务 `SYNC` high time | ≥ 15 ns | ≥ 50 ns | SPI Master / transaction 间隔 |
| `SYNC↑` 到 `BUSY↓` | 最大 40 ns | SPI done 后先等待 ≥ 100 ns 再检测 BUSY | AD5560 Driver |
| Readback 两帧之间 `SYNC` high time | ≥ 250 ns | 两次 SPI transaction 间隔 ≥ 500 ns | AD5560 Driver |
| `SYNC↑` 到 SDO high-Z | 最大 30 ns | 下一次 SPI transaction 不早于普通 CS high guard | SPI Master / transaction 间隔 |

上述建议值以逻辑简单和留有裕量为优先，不追求极限 SPI 吞吐率。

### 4.1 SPI Master 对 CS_n / SYNC 的职责

SPI Master 内部直接管理 `CS_n / SYNC`，Driver 不再单独控制片选。

SPI Master 至少需要支持：

```text
目标器件 / CS 编号
发送数据
传输长度
SPI 时钟配置
start / valid
ready / done
接收数据
```

对于本 BUS 的 16 颗 AD5560，可由 SPI Master 接收 `DEVICE_ID` 并输出 16 路独立 `CS_n / SYNC`。

任何时刻只允许一颗器件的 `CS_n / SYNC` 为低。

SPI Master 应保证一次 transaction 完成时已经完成：

```text
CS_n 拉低
→ SPI 移位
→ 保持必要 CS hold time
→ CS_n 拉高
→ done
```

因此 Driver 可以把 `spi_done` 作为 `SYNC↑` 已发生的时间基准。

### 4.2 BUSY 检测保护时间

AD5560 在 `SYNC / CS_n` 拉高、完成一笔写事务后，`BUSY` 不一定立即拉低。Datasheet 给出的最坏条件为 `SYNC↑` 后最多约 40 ns 才出现 `BUSY↓`。

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

由于 `SYNC` 由 SPI Master 作为 `CS_n` 自动控制，因此 Driver 只需要控制两次 SPI transaction 的启动间隔。

第一版按 **≥ 500 ns** 处理：

```text
第 1 次 SPI transaction done
此时 CS_n / SYNC 已拉高
    ↓
等待 ≥ 500 ns
    ↓
启动第 2 次 SPI transaction
SPI Master 再次拉低同一器件 CS_n / SYNC
```

因此不需要在 Driver 中额外实现一套 `SYNC` 状态机。

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

`SYNC / CS_n` 拉高后，SDO 最迟约 30 ns 回到 high-Z。

由于同一 BUS 上 16 颗 AD5560 共用 SDO，下一次 SPI transaction 必须满足 SPI Master 规定的最小 CS high time，确保上一颗器件已经释放 SDO 后再选择下一颗器件。

只要 SPI Master 保证：

```text
一次 transaction 只允许一个 CS_n 为低
transaction 之间满足最小 CS high time
```

Driver 不需要再额外控制器件切换时的 SYNC 保护逻辑。

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
      └─ SPI Master
            └─ CS_n / SYNC × 16
```

`Bus Service` 决定“下一笔执行什么事务”，`AD5560 Driver` 负责“把这一笔 AD5560 寄存器事务执行完成”，`SPI Master` 负责“完成单次 SPI transaction，包括 CS_n / SYNC 时序”。

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
