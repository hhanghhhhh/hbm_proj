# AD5560 Driver 设计

## 1. 模块定位

`AD5560 Driver` 对应一条 AD5560 SPI BUS，负责本组 16 颗 AD5560 的寄存器事务执行。

系统共实例化 8 个 Driver。

SPI 底层移位、时钟以及单路片选时序由通用 `SPI Master` 实现。`SPI Master` 只输出一根通用 `CS_n`，不知道 AD5560，也不知道本 BUS 上有 16 颗器件。

`AD5560 Driver` 负责：

- 接收并锁存一笔寄存器事务；
- 根据 `DEVICE_ID` 将 SPI Master 的 `CS_n` 映射到本组 16 路独立 `SYNC` 中的一路；
- 组织 AD5560 寄存器读写帧；
- 封装 readback 两帧流程；
- 处理 AD5560 专用时序和写事务 `BUSY`；
- `BUSY timeout` 时锁存本 BUS 的 `bus_fault`。

---

## 2. 每个 Driver 对应的硬件资源

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

## 3. 公共命令接口

Driver 直接使用 `valid / ready` 接收顶层公共命令通路送来的寄存器事务。业务模块只输出目标 `BUS_ID`，顶层 generate 根据固定 `BUS_ID` 选择对应 Driver；Driver 本身不参与跨 BUS 仲裁。

接口：

```text
cmd_valid
cmd_ready
cmd_rw
cmd_device_id[3:0]
cmd_reg_addr[6:0]
cmd_wr_data[15:0]
```

读事务返回：

```text
rsp_valid
rsp_rd_data[15:0]
```

故障接口：

```text
bus_fault
bus_fault_clear
```

接口规则：

- Driver 空闲且无故障时 `cmd_ready = 1`；
- `cmd_valid && cmd_ready` 时 Driver 锁存本次 `RW / DEVICE_ID / REG_ADDR / WR_DATA`；
- 握手后 Driver 拉低 `cmd_ready` 并独立执行该事务，上层参数随后可以变化；
- 当前事务完成后重新进入可接收状态；
- 读事务完成时 `rsp_valid` 拉高 1 clk，同时 `rsp_rd_data` 有效；
- 普通写事务不需要上层等待完成响应；
- `BUSY timeout` 时置位 sticky `bus_fault` 并停止接收新的事务；
- `bus_fault_clear` 为单 clk 清除脉冲，由 `System Controller` 在完成系统 fault 锁存后发出。

---

## 4. 器件选择与 SYNC 映射

Driver 在命令握手时锁存 `DEVICE_ID`，并在本次事务执行期间保持不变。

SPI Master 只产生通用单路 `CS_n`，Driver 根据锁存的 `DEVICE_ID` 将其映射为对应 AD5560 的 `SYNC`：

```text
SYNC[0..15] = 全部保持高
SYNC[device_id] = spi_cs_n
```

实际 RTL 必须保证任何时刻最多只有一路 `SYNC` 为低。

---

## 5. AD5560 寄存器写

Driver 组织 AD5560 的 24 bit SPI 写帧并调用 SPI Master。

写事务结束后不能立即用当前 `BUSY=1` 判断完成，应先经过固定保护时间，再判断 BUSY。

不要求必须观察到一次 `BUSY=0`。如果 BUSY 低脉冲较短，在保护时间结束前已经恢复为高，可直接认为内部处理完成。

`BUSY` 等待需要设置 timeout。正常写事务 timeout 应明显大于 DAC x1 写入约 1.5 µs 的最坏 BUSY 时间，并留有裕量。

发生 timeout 时：

```text
bus_fault = 1
cmd_ready = 0
```

SPI 写本身没有 ACK，因此除 BUSY timeout 外，Driver 不判断“寄存器是否真正写入成功”。

### 5.1 bus_fault 清除

`bus_fault` 由 Driver 锁存，不能自动清除。

System Controller 检测到 fault 后先锁存系统级 `fault_vector`，随后向对应 Driver 发：

```text
bus_fault_clear = 1 pulse
```

Driver 收到清除脉冲后清除本地 sticky fault 并回到空闲状态。

---

## 6. AD5560 寄存器读

上层只发起一次寄存器读请求，Driver 内部完成两次 SPI transaction：

依据 AD5560 Rev.F SPI Read Timing：

- readback 两帧之间只要求满足 `SYNC` high time；
- **两帧之间不等待 BUSY**；
- 第二帧结束后等待 SDO 释放保护时间，再返回读结果。

第 2 帧使用 NOP，避免为了移出 readback 数据而修改其他寄存器。

---

## 7. SPI / AD5560 时序边界

| 项目 | Datasheet 要求 | 第一版建议 | 归属 |
|---|---:|---:|---|
| `SYNC↓` 到首个 SCLK falling edge | ≥ 10 ns | ≥ 50 ns | SPI Master CS setup |
| 第 24 个 SCLK falling edge 到 `SYNC↑` | ≥ 5 ns | ≥ 50 ns | SPI Master CS hold |
| 普通事务 `SYNC` high time | ≥ 15 ns | ≥ 50 ns | SPI Master / transaction 间隔 |
| 写事务 `SYNC↑` 到 `BUSY↓` | 最大 40 ns | SPI done 后等待 ≥ 100 ns 再检测 BUSY | Driver |
| Readback 两帧之间 `SYNC` high time | ≥ 250 ns | ≥ 500 ns，不等待 BUSY | Driver |
| `SYNC↑` 到 SDO high-Z | 最大 30 ns | 下一事务前满足保护时间 | Driver / SPI Master |

上述建议值优先保证 RTL 简单和时序裕量，不追求极限 SPI 吞吐率。

---

## 8. 多 BUS 工作方式

系统实例化 8 个独立 `AD5560 Driver`。业务模块输出 `BUS_ID`，顶层 generate 中各 Driver 通过固定 `BUS_ID` 比较自动选择。

```text
不同 BUS：可以同时执行 SPI 事务
同一 BUS：Driver 自身一次只接受一笔事务，自动串行
```

8 路 Driver 的 `bus_fault` 输出统一送到 `System Controller`，由其进行系统级 fault 锁存和处理。
