# Config Manager 重构约束

## 1. 指令与接口

- 统一执行 AD5560 通用指令，不区分上电、下电或 Ramp 业务；上层可按任意 BUS、Device 顺序下发。
- 沿用现有 32-bit Record：`[31:30]` 为 OP；`00=WRITE`，`01=DELAY`，其余保留。
- WRITE 沿用 `BUS_ID / DEVICE_ID / REG_ADDR / REG_DATA` 字段；DELAY 使用 `REG_DATA[15:0]` 表示毫秒。
- **DELAY 0 = BARRIER**；DELAY 必须等前序全部 BUS 的 SPI 事务完成后才开始计时，之后才能执行下一阶段。
- 指令表结束也必须等待所有 BUS 完成后才报告 Done。
- Config 对外保持现有公共命令握手与 `o_cmd_bus_id` 等字段，不改成 8 组输出接口。

## 2. 多 BUS 调度

- 保留一个全局 Config Manager，负责原始指令表、CRC、分发、全局 DELAY 和完成控制。
- 8 个独立 BUS Executor（同一参数化模块例化），各自维护 RAM/队列和执行进度；共享现有公共命令输出，通过内部仲裁提交。
- 全局按原始 Record 顺序读取，将 DELAY 前的 WRITE 按 BUS_ID 分发；**本阶段分发完再启动各 BUS 并行执行**。
- 同一 BUS 严格按原 Record 顺序执行；不同 BUS 可乱序、并行完成。跨 BUS 有顺序依赖时，由上层插入 DELAY 0。
- 仲裁采用 Round-Robin，BUS busy 不得阻塞其他 ready BUS；不要求上层按 BUS 排序、分区或添加 Header。

## 3. RAM、状态与异常

- **全局 Config RAM 保持 1024 × 32-bit**，CRC16/MODBUS 校验流程保持；各 BUS 队列需容纳任意合法 1024 条指令在单阶段集中于一个 BUS 的情况。
- 保留现有 Busy / Done / Error / Abort 语义，保留**全局 Record 位置**用于 Debug（指原始表读取/分发位置，不表示各 BUS 的 SPI 完成位置）。
- 非法指令不得执行；执行中 Abort/故障立即停止后续命令提交，清除未执行队列；已接收的 SPI 事务按既有排空机制处理，不自动恢复。
- DELAY/BARRIER 只保证 SPI 事务完成，不代表 Ramp 到达目标电压。

