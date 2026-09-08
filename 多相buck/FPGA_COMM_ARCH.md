# FPGA 通信架构

本文只描述 FPGA 通信子系统的**总体分层、模块边界和长期保持的全局约束**，作为快速理解工程的系统地图。

具体帧格式、CMD/Payload 定义和模块内部行为不在本文重复维护，分别以协议文档、命令定义和 RTL 顶部 `Module Contract` 为准。

## 1. 总体结构

```text
UART RX
   |
   v
Frame Parser
 [Payload RAM]
   |
   v
CMD Dispatcher
   |
   +--> 参数 / 状态业务
   +--> 控制业务
   +--> 配置业务
   +--> 在线升级等业务
   |
   +--> Error Response Generator
              |
              v
       Response Buffer
              |
              v
       TX Frame Builder
       [Response RAM]
              |
              v
           UART TX
```

通信层负责可靠收发、路由和统一响应链路；业务模块只处理具体 CMD 的业务含义。

当前系统采用严格单事务、一问一答模式：同一时刻只处理一个已接收请求，当前事务结束后再接受下一条业务请求。

## 2. 模块边界

### Frame Parser

- 负责可靠接收并校验完整通信帧；
- 内部保存 Payload RAM 和当前请求上下文；
- 只有可信完整帧才提交给后级；
- 不解释 Payload 的业务含义，不执行具体 CMD。

### CMD Dispatcher

- 根据 CMD 将合法请求路由到对应业务模块；
- 管理当前业务模块选择和 Payload RAM 读地址路由；
- 不执行具体业务，不负责响应组帧和发送。

### 业务模块

- 解析自身负责的 CMD 和 Payload；
- 执行业务逻辑并产生统一响应 Payload；
- 业务参数、状态或流程错误进入统一错误响应链路；
- 新功能优先通过新增 CMD 和业务模块扩展，不修改基础通信框架。

### Error Response Generator

- 处理“请求帧可信，但请求无法执行”的业务级错误；
- 使用与正常业务一致的响应链路；
- 不处理 CRC、非法长度、接收超时等不可信帧错误。

### Response Buffer

- 在正常业务响应和错误响应之间选择当前有效响应源；
- 向 TX Frame Builder 提供统一响应接口；
- 不保存 Response RAM，不生成完整通信帧。

### TX Frame Builder

- 内部保存 Response RAM；
- 统一生成正常响应和错误响应的完整发送帧；
- 负责 CRC、UART TX 握手及 RS485 发送方向控制；
- 发送侧事务完成的精确定义以 `rtl/tx_frame_builder.v` 顶部 `Module Contract` 为准。

## 3. 全局不变量

以下规则属于通信框架的长期约束，修改时需要明确评估整个通信链路：

1. **通信层与业务层分离。** Frame Parser 不解释业务，业务模块不处理基础收帧可靠性。
2. **可信后执行。** CRC、长度等基础校验通过后，请求才允许进入业务处理。
3. **不可信帧静默丢弃。** SOF/接收超时/非法长度/CRC 错误等不生成业务错误响应。
4. **可信请求的业务错误统一响应。** 未定义 CMD、参数非法、状态不允许等通过 Error Response Generator 返回错误。
5. **严格单事务。** 当前问答事务未结束前，不启动下一条业务事务。
6. **响应上下文沿用请求。** 正常响应和错误响应均沿用当前请求的 ADDR、CMD、SEQ。
7. **SEQ 只用于请求/响应匹配。** 当前不提供自动去重、历史响应缓存或并发事务编号能力。
8. **Response Payload 首字节为 STATUS。** 具体格式以 `COMMUNICATION_PROTOCOL.md` 为准。
9. **Payload RAM 为同步读接口，固定 1clk 读取延迟。** 业务模块按该接口时序读取请求 Payload。
10. **事务事件与字节握手区分。** `frame_valid`、业务 `req_valid`、`rsp_valid`、事务完成类信号属于事件脉冲；UART 字节侧 `tx_valid`/`tx_ready` 属于握手接口，`tx_valid` 可在等待 `tx_ready` 时保持。
11. **事务异常可恢复。** 事务超时/abort 应使当前链路最终回到可接收下一事务的状态；各模块的具体清理行为由自身 `Module Contract` 定义。

## 4. 单一事实来源

为避免同一约束在多份文档中重复维护，以下内容只在对应位置作为当前事实来源：

| 内容 | 当前事实来源 |
|---|---|
| 总体分层、模块边界、全局不变量 | `FPGA_COMM_ARCH.md` |
| 帧格式、CRC 范围、请求/响应通用规则 | `COMMUNICATION_PROTOCOL.md` |
| CMD 分类、请求/响应 Payload 语义 | `CMD_DEFINITION.md` |
| 单个 RTL 的当前外部行为、握手、时序、abort/reset 语义 | 对应 `.v` 文件顶部 `Module Contract` |
| RTL 编码和 Module Contract 写法 | `VERILOG_CODING_GUIDELINES.md` |
| 是否已经被验证、覆盖了什么、还有什么未证明 | 当前 Cocotb 验证报告 |

早期的 `FRAME_PARSER.md`、`CMD_DISPATCHER.md`、`TX_FRAME_BUILDER.md`、`RESPONSE_BUFFER.md`、`ERROR_RESPONSE.md` 等模块设计文档可继续保留作为**历史设计输入和讨论记录**，但不要求随 RTL 持续同步，也不作为当前模块行为的唯一依据。

当这些历史文档与协议、当前 RTL `Module Contract` 或已确认的新需求冲突时，应先确认当前设计意图，再更新真正的事实来源和验证用例，而不是机械同步所有旧文档。

## 5. 阅读与修改路径

日常维护建议按以下顺序读取，避免为小改动重读整个工程：

```text
先看 FPGA_COMM_ARCH.md
        |
        +--> 涉及协议：COMMUNICATION_PROTOCOL.md
        |
        +--> 涉及业务：CMD_DEFINITION.md
        |
        +--> 涉及某模块：对应 RTL 顶部 Module Contract
                              |
                              +--> 需要排查实现时再读模块内部 RTL
                              |
                              +--> 需要确认正确性时看 Cocotb 验证报告
```

模块外部可观察行为发生变化时，应同步更新该 RTL 的 `Module Contract` 和相关验证；仅内部实现重构且外部契约不变时，不要求修改本文。