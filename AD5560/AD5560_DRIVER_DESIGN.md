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

为简化第一版设计，可统一采用 **10 MHz SCLK**。。

---

## 3. 主要功能

### 3.1 器件选择与 SYNC 映射

上层提供 `DEVICE_ID`，Driver 在本次事务开始前锁存目标器件编号。

Driver 根据锁存的 `DEVICE_ID` 将该 `CS_n` 映射为对应 AD5560 的 `SYNC`。

实际 RTL 需保证任何时刻最多只有一路 `SYNC` 为低。

### 3.4 BUSY 处理

每条 BUS 的 16 颗 AD5560 共用一根开漏 `BUSY`，由对应 `AD5560 Driver` 直接检测。

`BUSY` 主要用于写事务以及 RESET / 上电等内部处理状态。Datasheet 的 BUSY Function 明确说明寄存器写会使 BUSY 拉低；readback 时序图不要求在两帧之间等待 BUSY。

为避免在前一笔写操作尚未完成时启动新的访问，**任何新事务开始前仍应先确认共享 `BUSY` 已释放。**

### 3.2 AD5560 寄存器写

上层提供：

```text
DEVICE_ID
REG_ADDR
REG_DATA
```

`AD5560 Driver` 负责组织 AD5560 的 24 bit SPI 写帧，并调用 `SPI Master` 完成一次完整 SPI transaction。

对于写事务，Driver 不能在 SPI 完成的同一时刻立即判断 `BUSY`，而应先经过固定保护时间，再判断器件是否仍处于 BUSY。

对于写事务，不要求必须观察到一次 `BUSY=0`。如果 BUSY 低脉冲较短，在保护时间结束前已经恢复为高，可直接认为器件内部处理已经结束。

`BUSY` 等待需要设置 timeout，避免器件异常导致上层流程永久阻塞。

AD5560 的 DAC x1 写入 BUSY low 最长约 1.5 µs，其他寄存器写入最长约 280 ns，因此正常写事务的 BUSY timeout 应明显大于 1.5 µs，并留有板级和时钟裕量。

写结束已经等待 busy 固定时长了，且大于 `SYNC↑` 到 SDO high-Z，无需重复等待。

### 3.3 AD5560 寄存器读

上层只发起一次寄存器读请求。

AD5560 readback 由 Driver 内部封装为两次独立 SPI transaction：

依据 AD5560 Rev.F 的 SPI Read Timing，readback 两帧之间只要求满足最小 `SYNC` high time；**读事务两帧之间不等待 BUSY，也不执行写事务的 BUSY 检测流程。**

因此 readback 要求的 `SYNC` high time，本质上就是两次 SPI transaction 之间的间隔。

第 2 帧使用 NOP，避免为了移出 readback 数据而修改其他寄存器。

读后，注意 `SYNC` 拉高后，SDO 最迟约 30 ns 回到 high-Z。这个等待时间需放在读取后，然后再回复 resp_valid。

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
      ├─ 写事务 BUSY / readback 控制
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
