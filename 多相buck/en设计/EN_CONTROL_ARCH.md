# EN 控制架构

本文描述 EN 控制子系统的**总体结构、模块边界和全局约束**，作为架构入口。以下为 V1 目标架构，新增模块尚待实现；GROUP 格式、报文和具体例子见 [DUT_POWER_CONTROL_V1.md](DUT_POWER_CONTROL_V1.md)。

## 1. 总体结构

```text
PC RS485 → 现有通信层 / CMD Dispatcher
                         |
                         v
              en_control_application
                  |      |       |
       sequence写入|      |       |模式 / 提交 / 清故障请求
                  v      |       v
 en_sequence_controller  |  en_power_manager ← START_SYNC
       [sequence RAM]    |       |
                         |       +→ 序列启动 / 运行许可
               GROUP配置/读回
                         v
              group_map_controller
                  [映射 RAM]
                         ↕ 查表请求 / 结果
本地故障 ─────→ power_fault_controller
                         ↕ 组级故障 / 执行完成
               fault_bus_controller
                         ↕
               FAULT_REQ、FAULT_A/B

sequence_en ──────┐
debug_en ─────────┼→ en_power_manager → 实际 EN 引脚
fault_inhibit ────┘
```

上位机预先计算保护组并生成映射；FPGA 只保存、查表和执行。`hbm_comm_top.v` 负责各模块连接，PC 通信与实时故障处理相互独立。

## 2. 模块边界

| 模块 | 职责 |
|---|---|
| `en_control_application`，现有扩展 | PC 命令入口；解析直接 EN、sequence、GROUP 写入/读回、配置提交和清故障请求，产生统一响应。不执行实时查组或板间通信。 |
| `en_sequence_controller`，现有保留 | 内部保存 sequence RAM，执行正常 ON/OFF sequence，输出 `sequence_en`。不解析 DUT/GROUP。 |
| `group_map_controller`，新增 | 保存表 A（row+1）、升序紧凑表 B 和元数据；本地直接索引、远端二分查找，返回 GROUP_ID、本地 row、EN_MASK 和匹配状态。 |
| `power_fault_controller`，新增 | 锁存本地故障，统一组织运行时查表；维护 `fault_inhibit`、`group_fault`、`pending`，提交发送请求，反馈远端关断执行结果。 |
| `fault_bus_controller`，新增 | 仲裁、故障帧收发、CRC、ACK 和重试；与故障控制模块交换组级请求，不直接访问映射 RAM 或控制 EN。 |
| `en_power_manager`，新增 | 管理配置/正常/调试状态、启动许可、START_SYNC 与序列启动；检查清故障条件，选择 EN 来源并统一施加故障屏蔽。 |

GROUP 下发继续走 `en_control_application`，存储和查找放在 `group_map_controller`；UART、CRC、RAM IP 作为对应模块的底层组成。

## 3. 主要数据流

| 场景 | 流程 |
|---|---|
| 配置下发 | PC → application 解析 OFFSET/DATA → map_controller 写 RAM → 读回核对 → 独立提交配置。写命令成功不等于整套配置有效。 |
| 本地故障 | fault_controller 先屏蔽故障通道 → 表 A 得 row+1，检查后减一 → 直接读表 B 得 GROUP_ID/MASK → 锁存整组 inhibit、置 pending[row]。 |
| 待发送故障 | fault_controller 选择 pending[row] → 按 row 读取表 B 的 GROUP_ID → bus_controller 广播并处理 ACK/重试。 |
| 远端故障 | bus_controller 提交合法 GROUP_ID → fault_controller 请求二分查找表 B → 锁存本板 MASK → 反馈执行完成 → bus_controller 在本板时隙 ACK。 |
| 正常上/下电 | power_manager 接收有效 START_SYNC 边沿 → 启动对应 sequence → 正常 EN 经模式选择和故障屏蔽后输出。 |

映射模块提供三种查询：**按通道查、按 GROUP_ID 查、按本地 row 读**。查询使用请求/结果接口，一次处理一个；初版 PC 映射读回仅在停机配置阶段开放，运行期由故障控制模块使用查表接口。

上位机先将表 B 按 GROUP_ID 严格升序排列，再生成表 A 的 row+1（0 表示未使用）。映射仍预留本板最多 128 行，数据容量 2.5 KiB；远端最多比较 8 次 ID，本地和 pending 按 row 直接读取，不扩大为全局组号索引数组。

## 4. 全局约束

1. **配置与执行分离。** 配置仅在停机状态更新；应用模块不参与实时故障闭环，PC 事务 abort 不清除故障锁定。
2. **本地立即保护，远端执行后 ACK。** 本地故障通道先关闭，不等待通信；接收请求被接受与关断执行完成是两个不同事件。
3. **故障状态单一维护。** inhibit/group_fault/pending 由故障控制模块维护；manager 只提交满足条件的清除请求并使用 inhibit。新故障置位优先于清除。
4. **故障覆盖所有 EN 来源。** 正常和调试输出都受屏蔽；START_SYNC 不直接选择 normal/debug。组故障不使用会清零全板的 sequence 急停接口。
5. **请求不能因忙碌丢失。** 本地故障先锁存；查表及总线请求通过握手保持/缓存。发送完成只清待发送状态，不清故障 inhibit。
6. **全局组号与本地行号分离。** 板间只传 GROUP_ID；本地 row 用于 RAM 和 pending。配置有效且本板无该组时可以 ACK，不转发收到的同一 KILL。

最终输出关系：

```verilog
actual_en = selected_en & valid_channel_mask
          & ~fault_inhibit_mask & {128{output_permit}};
```

## 5. 实现状态与参考

当前已有 `en_control_application` 和 `en_sequence_controller`；顶层实际 EN 仍连接 `debug_en_state[111:0]`，尚未接入上述完整管理、映射和故障链路。系统内部按 128 路组织，当前物理输出为低 112 路。

- 整体通信分层与响应链路：[FPGA_COMM_ARCH.md](../FPGA_COMM_ARCH.md)。
- GROUP 数据、故障流程、通信参数和示例：[DUT_POWER_CONTROL_V1.md](DUT_POWER_CONTROL_V1.md)。
- 实现后的精确接口、RAM 延迟和 reset/abort 行为：以对应 RTL 的 `Module Contract` 为准；本文不重复维护逐信号定义。
