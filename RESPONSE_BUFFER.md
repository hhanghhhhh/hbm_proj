# Response Buffer 模块设计约束

## 1. 模块定位

Response Buffer 位于业务模块与 `TX Frame Builder` 之间，负责统一缓存和提交业务响应。

职责：

- 提供共享的 Response RAM；
- 根据 `CMD Dispatcher` 输出的 `active_module`，选择当前业务模块的响应写接口；
- 在业务模块完成响应数据写入后，向 `TX Frame Builder` 提交一次发送请求；
- 向 `TX Frame Builder` 提供响应 Payload RAM 读取接口。

Response Buffer 不解析业务含义，不生成具体帧格式，不负责等待发送完成。

---

## 2. 基本架构

```text
业务模块
   |
   | rsp_wr_en / rsp_wr_addr / rsp_wr_data
   | rsp_length / rsp_valid
   v
Response Buffer
   |
   | Response RAM
   | tx_start / cmd / seq / length
   v
TX Frame Builder
   |
   v
UART TX
```

系统采用单事务、一问一答模式，同一时刻只允许一个业务模块产生响应。

---

## 3. 业务响应接口

各业务模块使用统一响应接口：

```text
rsp_wr_en
rsp_wr_addr
rsp_wr_data
rsp_length
rsp_valid
```

约束：

- 业务模块先完成 Response RAM 数据写入，再产生 `rsp_valid`；
- `rsp_valid` 表示当前响应已准备完成，可开始发送；
- Response Buffer 仅采纳 `active_module` 对应业务模块的响应接口；
- 请求的 `CMD`、`SEQ` 等事务信息由当前请求上下文提供，业务模块原则上不自行管理。

---

## 4. Response RAM

所有业务模块共用一块 Response RAM。

各业务模块的 `rsp_wr_*` 接口通过 `active_module` 进行 MUX 后写入该 RAM。

`TX Frame Builder` 通过统一读接口读取 Response RAM 中的 Payload。

从 `rsp_valid` 提交响应开始，到当前响应发送完成之前，Response RAM 不允许被再次改写。

---

## 5. 与发送链路的关系

Response Buffer 收到当前业务模块的 `rsp_valid` 后，向 `TX Frame Builder` 产生一次 `tx_start`，同时提供当前响应所需的 `CMD`、`SEQ`、`LENGTH` 等信息。

Response Buffer 不等待 `tx_done`，也不负责恢复接收。

当前响应发送完成后，由发送链路的 `tx_done` 直接通知 `Frame Parser` 释放当前请求并恢复下一帧接收。

---

## 6. 扩展原则

新增业务模块时：

- 保持统一响应接口；
- 增加对应响应写接口到 Response Buffer 的 MUX；
- 继续共用统一 Response RAM；
- 不修改 `TX Frame Builder` 和基础帧格式。

---

## 7. 设计原则总结

1. 业务模块只负责生成响应 Payload，不直接生成通信帧。
2. 所有业务模块共用一块 Response RAM。
3. `active_module` 同时用于请求路由和响应写接口选择。
4. `rsp_valid` 表示响应数据已准备完成，并触发后续发送。
5. Response Buffer 不等待发送完成。
6. `tx_done` 直接用于结束当前问答事务并恢复接收。
