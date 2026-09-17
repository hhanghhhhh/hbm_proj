# AD5560 Config Manager 设计

## 1. 模块定位

`Config Manager` 负责执行 AD5560 的初始化配置表。

其职责仅限于：

- 接收通信侧写入的配置记录；
- 保存配置记录；
- 配置启动后按顺序读取记录；
- 将每条记录转换成一笔 AD5560 寄存器写事务；
- 等待该事务真正执行完成后继续下一条；
- 出错时记录当前配置索引并结束本次配置。

`Config Manager` 不负责运行期遥测、上下电时序或其他动态寄存器控制。

后续 FPGA 内部如需运行期读写 AD5560 寄存器，应由独立功能模块直接通过 `Command Arbiter` 访问 `Bus Service`，不经过 `Config Manager`。

---

## 2. Config RAM

第一版将 **Config RAM 直接放在 `Config Manager` 内部**。

```text
Config Manager
├─ Config RAM
│   ├─ 写口：通信侧写入配置记录
│   └─ 读口：Config Manager 顺序读取
│
└─ Config FSM
```

Config RAM 采用单块全局 RAM，不按 8 条 SPI BUS 分开。

通信侧先完成配置表写入，再启动配置。配置执行期间不允许修改当前 Config RAM。

### 2.1 配置记录

每条配置记录包含：

```text
BUS_ID      3 bit
DEVICE_ID   4 bit
REG_ADDR    7 bit
REG_DATA   16 bit
```

共 30 bit，可使用 32 bit RAM，剩余位保留。

第一版 Config Table 只执行寄存器写操作，因此记录中不需要 `RW` 字段。

---

## 3. 通信侧接口

通信侧只需要完成配置 RAM 写入和启动控制，建议接口：

```text
cfg_ram_wr_en
cfg_ram_wr_addr
cfg_ram_wr_data[31:0]

cfg_start
cfg_record_count

cfg_busy
cfg_done
cfg_error
cfg_error_index
```

其中：

- `cfg_start` 为单 clk 启动脉冲；
- `cfg_record_count` 表示本次需要执行的有效记录数量；
- `cfg_busy` 表示正在执行配置；
- `cfg_done` 表示本次配置正常结束；
- `cfg_error` 表示本次配置因事务错误结束；
- `cfg_error_index` 保存出错记录索引。

---

## 4. 配置执行流程

第一版采用完全串行执行，不利用 8 条 BUS 做并行配置。

基本流程：

```text
IDLE
  ↓
cfg_start
  ↓
index = 0
  ↓
读取 Config RAM[index]
  ↓
解析 BUS_ID / DEVICE_ID / REG_ADDR / REG_DATA
  ↓
向 Command Arbiter 提交一笔寄存器写事务
  ↓
等待目标 Bus Service 真正执行完成
  ↓
成功：index + 1
失败：记录 error_index 并结束
  ↓
全部记录完成后 cfg_done
```

配置时间不是系统瓶颈，因此同一时刻只允许一笔配置事务在途。

这样可以保证：

- 配置记录和执行结果一一对应；
- 错误索引明确；
- 不需要维护多 BUS pending 状态；
- 第一版状态机保持简单。

---

## 5. 与 Command Arbiter 的接口

`Config Manager` 作为一个前台命令源，通过 `Command Arbiter` 访问目标 `Bus Service`。

建议输出：

```text
cfg_cmd_valid
cfg_cmd_ready
cfg_bus_id[2:0]
cfg_device_id[3:0]
cfg_reg_addr[6:0]
cfg_wr_data[15:0]
```

由于 Config Table 第一版只有写操作，`Config Manager` 不需要内部保存 `RW` 字段；送入统一命令接口时固定为寄存器写。

返回：

```text
cfg_rsp_valid
cfg_rsp_error
```

执行原则：

```text
cfg_cmd_valid && cfg_cmd_ready
```

表示当前配置记录已被下游接收。

`Config Manager` 随后等待 `cfg_rsp_valid`，确认该寄存器写事务已经真正完成后，才继续读取下一条配置记录。

---

## 6. 与其他模块的边界

```text
Config Manager
      │
      │ 初始化配置事务
      ▼
Command Arbiter
      │
      ▼
Bus Service × 8
      │
      ▼
AD5560 Driver
```

`Config Manager` 只负责初始化配置表执行。

`Power Sequence Engine` 和后续可能增加的运行期控制模块作为独立前台命令源，也通过同一个 `Command Arbiter` 访问 `Bus Service`。
