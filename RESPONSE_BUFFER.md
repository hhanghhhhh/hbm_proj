# Response Buffer 模块设计约束

## 1. 模块定位

Response Buffer 位于业务模块与 `TX Frame Builder` 之间，负责将当前业务模块的响应接口统一路由到发送模块。

当前保留 `Response Buffer` 名称，但该模块不包含 Response RAM。

职责：

- 根据 `CMD Dispatcher` 输出的 `active_module`，选择当前业务模块的响应接口；
- 将选中的响应写接口统一输出给 `TX Frame Builder`；
- 保证同一时刻只有当前业务模块能够驱动发送侧响应接口。

Response Buffer 不解析业务含义，不缓存 Payload，不生成帧格式，不负责 CRC，也不等待发送完成。

---

## 2. 基本架构

```text
PARAM rsp_*  ----\
CTRL rsp_*   -----\
CONFIG rsp_* ------> Response Buffer ----> TX Frame Builder
FW rsp_*     -----/        ^
其他模块     ----/         |
                      active_module
```

系统采用严格单事务、一问一答模式，同一时刻只允许一个业务模块产生有效响应。

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

Response Buffer 根据 `active_module` 对整组接口进行 MUX，并输出一组同名统一接口给 `TX Frame Builder`。

约束：

- 仅采纳 `active_module` 对应业务模块的响应信号；
- 未被选中的业务模块不得影响发送链路；
- 业务模块先完成响应 Payload 写入，再产生 `rsp_valid`；
- `rsp_valid` 表示当前响应已准备完成，可以由 `TX Frame Builder` 开始发送。

---

## 4. 与其他模块的边界

`CMD Dispatcher` 只提供 `active_module` 作为请求和响应两侧统一的业务模块选择依据。

Response RAM 位于 `TX Frame Builder` 内部，Response Buffer 不持有任何响应数据缓存。

`tx_done` 由 `TX Frame Builder` 产生，并直接用于结束当前问答事务；Response Buffer 不需要接收或处理 `tx_done`。

---

## 5. 扩展原则

新增业务模块时：

- 保持统一响应接口；
- 增加该业务模块到 Response Buffer 的 MUX；
- 使用同一个 `active_module` 进行选择；
- 不修改 `TX Frame Builder` 的业务无关接口和基础帧格式。

---

## 6. 设计原则总结

1. Response Buffer 只负责响应接口 MUX。
2. Response Buffer 不包含 Response RAM。
3. 所有业务模块使用统一响应接口。
4. `active_module` 作为响应侧选择依据。
5. Response RAM、帧生成和发送握手均由 `TX Frame Builder` 负责。
