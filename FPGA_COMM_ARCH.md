# FPGA 通信架构设计说明

## 1. 目的

本文定义 FPGA 内部通信处理模块的总体架构。

设计目标：

- 通信协议解析与业务功能解耦；
- 支持参数/状态读取、设备控制、大块配置传输、在线升级等功能；
- 通信数据经过完整校验后再进入业务处理；
- 便于后续扩展 CMD 和维护。

---

## 2. 总体架构

FPGA 通信模块采用分层设计：

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
   +--> 参数/状态模块
   +--> 控制模块
   +--> 配置模块
   +--> 在线升级模块
   +--> 其他业务模块
   |
   +--> Error Response Generator
              |
              v
       Response Buffer
       [response MUX]
              |
              v
       TX Frame Builder
       [Response RAM]
              |
       tx_byte / tx_valid
              v
           UART TX
              ^
           tx_ready

TX Frame Builder --tx_done--> Frame Parser
```

当前通信采用严格单事务、一问一答模式：主机发送一个请求，等待完整响应后再发送下一请求。

---

## 3. Frame Parser

职责：

- SOF 检测；
- ADDR、CMD、SEQ、LENGTH 字段解析；
- PAYLOAD 接收并写入内部 Payload RAM；
- CRC 流式计算与校验；
- 长度检查和接收异常处理；
- 保存当前合法请求元信息直到当前事务结束。

约束：

- 不解析业务含义；
- 不处理具体 CMD；
- CRC 校验通过后才提交给后级；
- SOF、接收超时、非法长度、CRC 错误等不可信帧直接丢弃，不生成错误响应；
- 当前响应完成前，不接受下一条业务请求。

详细约束见 `FRAME_PARSER.md`。

---

## 4. CMD Dispatcher

职责：

- 根据 CMD 将请求分发到对应业务模块；
- 输出当前 `active_module`；
- 统一管理 Payload RAM 读地址路由；
- 对未知或未分配 CMD 产生错误请求。

约束：

- 只负责请求路由，不执行具体业务逻辑；
- 不直接生成正常或错误通信帧；
- 不负责当前事务结束控制。

详细约束见 `CMD_DISPATCHER.md`。

---

## 5. 业务模块

业务模块负责具体 CMD 的业务处理，并通过统一响应接口生成正常响应 Payload。

业务模块发现参数、状态、流程等业务错误时，进入统一错误响应机制，不自行生成完整错误帧。

主要业务类别包括：

- 参数 / 状态；
- 控制；
- 配置数据；
- 在线升级；
- 批量读取；
- 后续扩展模块。

---

## 6. Error Response Generator

Error Response Generator 只处理“请求帧合法，但请求无法执行”的情况，例如未知 CMD、参数非法、设备状态错误等。

它使用与普通业务模块一致的响应接口生成错误 Payload，并通过正常发送链路发送。

不可信接收帧不进入 Error Response Generator。

详细约束见 `ERROR_RESPONSE.md`。

---

## 7. 配置和大数据处理原则

配置数据和固件数据采用分包传输。

关键配置采用先缓存、校验、再提交生效的方式，禁止在数据未完整校验前直接修改有效配置。

---

## 8. Response Buffer

Response Buffer 仅负责：

- 根据 `active_module` 选择当前业务模块的正常响应接口；
- 在错误响应有效时选择 Error Response Generator；
- 将最终选中的 `rsp_wr_*`、`rsp_length`、`rsp_valid` 统一路由到 `TX Frame Builder`。

Response Buffer 不包含 Response RAM，不解析业务，不生成帧格式，也不等待发送完成。

详细约束见 `RESPONSE_BUFFER.md`。

---

## 9. TX Frame Builder

TX Frame Builder 内部包含 Response RAM，并负责统一生成完整响应帧。

正常响应和错误响应均沿用当前请求的：

```text
ADDR
CMD
SEQ
```

发送过程中按实际发送字节流式累计 CRC，通过 `tx_byte` / `tx_valid` / `tx_ready` 与 UART TX 逐字节握手。

最后一个 CRC 字节被 UART TX 接收后产生 `tx_done`。`tx_done` 用于结束当前问答事务，并通知 `Frame Parser` 恢复下一帧接收。

详细约束见 `TX_FRAME_BUILDER.md`。

---

## 10. 待确认事项

当前仍需后续统一确定：

- 错误码具体编号及是否需要附加错误信息；
- CRC 的具体算法参数。

---

## 11. 设计原则总结

1. 通信层与业务层分离。
2. Frame Parser 内部保存接收 Payload RAM，并负责可靠收帧。
3. 不可信接收帧直接丢弃，不返回错误响应。
4. CMD Dispatcher 只负责请求路由，未知 CMD 进入统一错误响应机制。
5. 业务模块只负责具体业务和正常响应 Payload。
6. Error Response Generator 统一生成业务级错误响应 Payload。
7. Response Buffer 只负责响应接口 MUX。
8. TX Frame Builder 内部保存 Response RAM，并统一生成和发送正常/错误通信帧。
9. 响应 ADDR、CMD、SEQ 均沿用当前请求。
10. 当前响应完成后才允许处理下一条请求。
11. 新功能优先通过增加 CMD 和业务模块实现，不修改基础通信框架。
