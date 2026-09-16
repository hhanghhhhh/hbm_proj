# AD5560 Driver 设计

## 1. 模块定位

`AD5560 Driver` 对应一条 AD5560 SPI BUS，负责本组 16 颗 AD5560 的寄存器事务执行。

上层只需要描述“访问哪颗器件、读写哪个寄存器、写入什么数据”，`AD5560 Driver` 负责完成对应的 AD5560 SPI 事务。

SPI 底层移位和时钟产生由通用 `SPI Master` 实现；AD5560 特有的器件选择、寄存器帧组织、读流程、`SYNC` 时序和 `BUSY` 处理均放在 `AD5560 Driver` 中。

`AD5560 Driver` 不负责配置表管理、上下电时序调度、BUS 选择或后台遥测轮询。

---

## 2. 每个 AD5560 Driver 对应的硬件资源

每个实例固定对应一条 SPI BUS：

```text
AD5560 Driver n
├─ SPI BUS n
├─ 16 路独立 SYNC
├─ 1 路共享 BUSY
└─ 1 个 SPI Master
```

每次事务只允许选择一颗 AD5560。

---

## 3. 主要功能

### 3.1 器件选择

上层提供 `DEVICE_ID`，`AD5560 Driver` 根据该编号控制本组对应的 `SYNC`。

### 3.2 AD5560 寄存器写

上层提供：

```text
DEVICE_ID
REG_ADDR
REG_DATA
```

`AD5560 Driver` 负责组织 AD5560 的 24 bit SPI 写帧，并调用 `SPI Master` 完成发送。

### 3.3 AD5560 寄存器读

上层只发起一次寄存器读请求。

AD5560 readback 由 Driver 内部封装为两次 SPI 操作：

```text
第 1 帧：发送 Read Request
    ↓
SYNC 拉高并等待 readback 间隔
    ↓
第 2 帧：发送 NOP，同时从 SDO 接收返回数据
    ↓
向上层返回 REG_DATA
```

第 2 帧使用 NOP，避免为了移出 readback 数据而修改其他寄存器。

上层模块不需要了解 AD5560 readback 的两帧流程。

### 3.4 BUSY 处理

每条 BUS 的 16 颗 AD5560 共用一根开漏 `BUSY`，由对应 `AD5560 Driver` 直接检测。

新事务开始前必须确认 `BUSY` 已释放。一次写事务完成后不能在 `SYNC` 拉高的同一时刻立即判断 `BUSY`，而应先经过固定保护时间，再判断器件是否仍处于 BUSY。

基本流程：

```text
接收寄存器事务
    ↓
确认 BUSY 已释放
    ↓
选择 DEVICE / SYNC 拉低
    ↓
执行 SPI transaction
    ↓
SYNC 拉高
    ↓
固定 BUSY 检测保护时间
    ↓
BUSY 已高：事务完成
BUSY 为低：继续等待 BUSY 拉高
    ↓
返回事务完成
```

不要求必须观察到一次 `BUSY=0`。如果 BUSY 低脉冲较短，在保护时间结束前已经恢复为高，可直接认为器件内部处理已经结束。

`BUSY` 等待需要设置 timeout，避免器件异常导致上层流程永久阻塞。

---

## 4. AD5560 专用时序约束

以下约束属于 `AD5560 Driver`，而不是通用 `SPI Master`。Driver 负责在调用 SPI Master 前后插入所需等待时间。

依据 AD5560 Rev.F datasheet Table 2：

| 项目 | Datasheet 要求 | Driver 建议预留 |
|---|---:|---:|
| `SYNC↓` 到首个 SCLK falling edge | ≥ 10 ns | ≥ 50 ns |
| 第 24 个 SCLK falling edge 到 `SYNC↑` | ≥ 5 ns | ≥ 50 ns |
| 普通事务 `SYNC` high time | ≥ 15 ns | ≥ 50 ns |
| `SYNC↑` 到 `BUSY↓` | 最大 40 ns | **先等待 ≥ 100 ns 再检测 BUSY** |
| Readback 两帧之间 `SYNC` high time | ≥ 250 ns | **≥ 500 ns** |
| `SYNC↑` 到 SDO high-Z | 最大 30 ns | 切换器件前至少保留普通 `SYNC` high guard |

上述建议值以逻辑简单和留有裕量为优先，不追求极限 SPI 吞吐率。

### 4.1 BUSY 检测保护时间

AD5560 在 `SYNC` 拉高、完成一笔写事务后，`BUSY` 不一定立即拉低。Datasheet 给出的最坏条件为 `SYNC↑` 后最多约 40 ns 才出现 `BUSY↓`。

因此禁止以下实现：

```text
SYNC↑
下一拍立即发现 BUSY=1
→ 判定事务完成
```

Driver 应先等待固定保护时间，例如 **100 ns**，再读取 `BUSY`：

```text
SYNC↑
    ↓
等待 100 ns
    ↓
BUSY = 0 → 等待 BUSY 回到 1
BUSY = 1 → 当前事务完成
```

AD5560 的 DAC x1 写入 BUSY low 最长约 1.5 µs，其他寄存器写入最长约 280 ns，因此正常寄存器事务的 BUSY timeout 应明显大于 1.5 µs，并留有板级和时钟裕量。

### 4.2 Readback 两帧间隔

Readback 模式要求两次 SPI 操作之间的 `SYNC` high time 至少为 **250 ns**。

Driver 第一版按 **500 ns** 处理：

```text
Read Request 帧结束 / SYNC↑
    ↓
等待 ≥ 500 ns
    ↓
SYNC↓
发送 NOP 帧并采集 SDO
```

该间隔由 Driver 保证，SPI Master 不需要知道 readback 是两帧事务。

### 4.3 Readback SCLK

AD5560 的 SDO 驱动较弱，readback 时不能直接按最高写入 SCLK 工作。Datasheet 给出的典型上限为：

```text
DVCC = 2.3 ~ 2.7 V：Readback SCLK ≤ 12 MHz
DVCC = 2.7 ~ 3.3 V：Readback SCLK ≤ 15 MHz
DVCC = 4.5 ~ 5.5 V：Readback SCLK ≤ 20 MHz
```

为简化第一版设计，可统一采用 **10 MHz readback SCLK**。写事务仍可使用独立的正常 SPI 时钟配置。

通用 `SPI Master` 只提供可配置时钟能力，具体在读事务中选择较低 SCLK 的策略由 `AD5560 Driver` 决定。

### 4.4 SDO 释放与器件切换

`SYNC` 拉高后，SDO 最迟约 30 ns 回到 high-Z。

由于同一 BUS 上 16 颗 AD5560 共用 SDO，Driver 必须保证上一颗器件的 `SYNC` 已拉高并经过必要保护时间后，才允许拉低下一颗器件的 `SYNC`，避免两个 SDO 驱动器短时间重叠。

任何时刻只允许一颗 AD5560 的 `SYNC` 为低。

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
```

`Bus Service` 决定“下一笔执行什么事务”，`AD5560 Driver` 只负责“把这一笔寄存器事务执行完成”。

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
