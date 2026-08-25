# TX Frame Builder 模块设计约束

## 1. 模块定位

TX Frame Builder 位于 `Response Buffer` 与 UART TX 模块之间，负责缓存响应 Payload 并生成完整发送帧。

职责：

- 内部提供 Response RAM，缓存当前响应 Payload；
- 接收 `Response Buffer` 输出的统一业务响应接口；
- 按通信协议生成 SOF、ADDR、CMD、SEQ、LENGTH、PAYLOAD、CRC；
- 发送过程中同步累计 CRC，不对 Payload 进行二次扫描；
- 通过 `tx_byte` / `tx_valid` / `tx_ready` 与 UART TX 模块逐字节握手；
- 最后一个 CRC 字节成功提交给 UART TX 后产生 `tx_done`。

TX Frame Builder 不解析具体业务含义。

---

## 2. 基本接口

来自 `Response Buffer` 的统一响应接口：

```text
rsp_wr_en
rsp_wr_addr
rsp_wr_data
rsp_length
rsp_valid
```

当前请求的 CMD、SEQ 等响应帧元信息由当前请求上下文提供，业务模块原则上不自行管理。

UART TX 接口：

```text
tx_byte
tx_valid
tx_ready
```

事务完成输出：

```text
tx_done
```

---

## 3. Response RAM

Response RAM 位于 TX Frame Builder 内部。

约束：

- 业务模块必须先完成全部 Payload 写入，再产生 `rsp_valid`；
- `rsp_valid` 表示当前响应 Payload 和长度已经准备完成，可以开始生成发送帧；
- 从 `rsp_valid` 开始到 `tx_done` 之前，Response RAM 不允许被再次改写；
- 支持 `LENGTH = 0` 的无 Payload 响应。

---

## 4. 发送握手

只有在：

```text
tx_valid && tx_ready
```

同时成立时，当前 `tx_byte` 才视为已成功提交给 UART TX。

当 `tx_ready = 0` 时，当前待发送字节及其有效状态必须保持，不得推进到下一字节。

发送字段顺序严格遵循 `COMMUNICATION_PROTOCOL.md`。

---

## 5. CRC 处理

CRC 规则必须与 `Frame Parser` 完全一致：

- SOF 不参与 CRC；
- ADDR、CMD、SEQ、LENGTH、PAYLOAD 在实际发送时逐字节累计 CRC；
- CRC 字段本身不再参与 CRC 计算；
- CRC 字节顺序遵循协议统一规定。

---

## 6. tx_done 定义

`tx_done` 在最后一个 CRC 字节完成一次 `tx_valid && tx_ready` 握手后产生。

其含义是：完整响应帧已经全部提交给 UART TX 模块，不要求等待串口线上最后一个停止位实际移出。

当前系统采用严格一问一答模式，`tx_done` 用于结束当前事务并通知 `Frame Parser` 恢复下一帧接收。

---

## 7. 与 Response Buffer 的边界

`Response Buffer` 仅负责根据 `active_module` 将当前业务模块的一组响应接口 MUX 成统一接口。

Response Buffer 不包含 Response RAM，也不负责帧生成、CRC、UART TX 握手或等待 `tx_done`。

---

## 8. 待确认事项

以下内容在具体实现前需要统一确定：

1. 非法 CMD、业务状态错误等异常响应由哪个模块产生，以及统一错误响应格式；
2. 响应 CMD 是否直接沿用请求 CMD，以及 STATUS 字段放置规则；
3. 响应帧 ADDR 的来源和规则；
4. CRC 的具体算法参数需要在 `COMMUNICATION_PROTOCOL.md` 中完整固定，包括多项式、初值、反射方式、最终异或和 CRC 字节顺序。

---

## 9. 设计原则总结

1. Response RAM 放在 TX Frame Builder 内部。
2. 业务模块只负责写响应 Payload 并提交 `rsp_valid`。
3. Response Buffer 只负责业务响应接口 MUX。
4. TX Frame Builder 统一负责帧格式和流式 CRC。
5. UART TX 采用 `tx_valid` / `tx_ready` 逐字节握手。
6. 最后一个 CRC 字节被 UART TX 接收后即产生 `tx_done`。
