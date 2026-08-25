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
              v
       Response Buffer
              |
              v
       TX Frame Builder
              |
              v
           UART TX
              |
           tx_done
              |
              +--------> Frame Parser
```

当前通信采用严格单事务、一问一答模式：主机发送一个请求，等待完整响应后再发送下一请求。

---

## 3. Frame Parser

职责：

- SOF 检测；
- ADDR、CMD、SEQ、LENGTH 字段解析；
- PAYLOAD 接收并写入内部 RAM；
- CRC 计算与校验；
- 长度检查和接收异常处理。

约束：

- 不解析业务含义；
- 不处理具体 CMD；
- CRC 校验通过后才提交给业务模块；
- 当前响应完整发送前，不接受下一条业务请求。

详细约束见 `FRAME_PARSER.md`。

---

## 4. CMD Dispatcher

职责：

- 根据 CMD 将请求分发到对应业务模块；
- 输出当前 `active_module`；
- 统一管理 Payload RAM 读地址路由。

约束：

- 只负责请求路由，不执行具体业务逻辑；
- 不负责响应发送和当前事务结束控制。

详细约束见 `CMD_DISPATCHER.md`。

---

## 5. 业务模块

业务模块负责具体 CMD 的业务处理，并通过统一响应接口生成响应 Payload。

主要业务类别包括：

- 参数 / 状态；
- 控制；
- 配置数据；
- 在线升级；
- 批量读取；
- 后续扩展模块。

业务模块不直接生成 UART 通信帧。

---

## 6. 配置和大数据处理原则

配置数据和固件数据采用分包传输。

关键配置采用先缓存、校验、再提交生效的方式，禁止在数据未完整校验前直接修改有效配置。

---

## 7. Response Buffer

Response Buffer 负责：

- 提供所有业务模块共用的 Response RAM；
- 根据 `active_module` 选择当前业务模块的响应写接口；
- 在业务模块提交 `rsp_valid` 后启动一次响应发送；
- 向 `TX Frame Builder` 提供响应 Payload 数据。

Response Buffer 不解析业务，不生成帧格式，也不等待发送完成。

详细约束见 `RESPONSE_BUFFER.md`。

---

## 8. TX Frame Builder

TX Frame Builder 根据当前响应信息统一生成完整发送帧，包括：

- SOF；
- ADDR；
- CMD；
- SEQ；
- LENGTH；
- PAYLOAD；
- CRC。

发送完整响应后产生 `tx_done`。

`tx_done` 用于结束当前问答事务，并通知 `Frame Parser` 释放当前请求、恢复下一帧接收。

---

## 9. 设计原则总结

1. 通信层与业务层分离。
2. Frame Parser 只负责可靠收帧。
3. CMD Dispatcher 只负责请求路由。
4. 业务模块只负责具体业务和响应 Payload。
5. Response Buffer 统一缓存和提交响应。
6. TX Frame Builder 统一生成通信帧。
7. 当前响应发送完成后才允许处理下一条请求。
8. 大数据采用分块传输，关键配置完整校验后再生效。
9. 新功能优先通过增加 CMD 和业务模块实现，不修改基础通信框架。
