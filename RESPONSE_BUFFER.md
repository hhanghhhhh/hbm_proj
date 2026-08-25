# Response Buffer 模块设计约束

## 1. 模块定位

Response Buffer 位于业务模块、Error Response Generator 与 `TX Frame Builder` 之间，负责将当前有效响应接口统一路由到发送模块。

Response Buffer 不包含 Response RAM。

职责：

- 根据 `CMD Dispatcher` 输出的 `active_module`，选择当前业务模块的正常响应接口；
- 在错误响应有效时，选择 Error Response Generator 的响应接口；
- 将最终选中的响应写接口统一输出给 `TX Frame Builder`；
- 保证同一时刻只有一个响应源能够驱动发送侧接口。

Response Buffer 不解析业务含义，不缓存 Payload，不生成帧格式，不负责 CRC，也不等待发送完成。

---

## 2. 基本架构

```text
PARAM rsp_*  ----\
CTRL rsp_*   -----\
CONFIG rsp_* ------\
FW rsp_*     -------+--> Response Buffer ----> TX Frame Builder
其他模块     ------/
ERROR rsp_*  -----/

active_module 用于正常业务响应选择。
错误响应有效时选择 ERROR 响应源。
```

系统采用严格单事务、一问一答模式，同一请求只能产生正常响应或错误响应之一。

---

## 3. 统一响应接口

所有正常业务模块和 Error Response Generator 均使用统一响应接口：

```text
rsp_wr_en
rsp_wr_addr
rsp_wr_data
rsp_length
rsp_valid
```

约束：

- 正常响应根据 `active_module` 选择；
- 错误响应有效时选择 Error Response Generator；
- 未被选中的响应源不得影响发送链路；
- 响应源先完成 Payload 写入，再产生 `rsp_valid`；
- `rsp_valid` 表示当前响应已准备完成，可以由 `TX Frame Builder` 开始发送。

严格单事务模式下，不考虑多个响应源同时有效的情况。

---

## 4. 与其他模块的边界

`CMD Dispatcher` 提供 `active_module` 用于正常业务响应选择。

Error Response Generator 作为独立特殊响应源接入，详细规则见 `ERROR_RESPONSE.md`。

Response RAM 位于 `TX Frame Builder` 内部，Response Buffer 不持有任何响应数据缓存。

`tx_done` 由 `TX Frame Builder` 产生，并直接用于结束当前问答事务；Response Buffer 不需要接收或处理 `tx_done`。

---

## 5. 扩展原则

新增业务模块时：

- 保持统一响应接口；
- 增加该业务模块到 Response Buffer 的 MUX；
- 使用同一个 `active_module` 进行正常响应选择；
- 不修改 `TX Frame Builder` 的业务无关接口和基础帧格式。

---

## 6. 设计原则总结

1. Response Buffer 只负责响应接口 MUX。
2. Response Buffer 不包含 Response RAM。
3. 正常业务和错误响应使用相同响应接口。
4. `active_module` 用于正常响应选择，错误响应作为特殊响应源接入。
5. Response RAM、帧生成和发送握手均由 `TX Frame Builder` 负责。
