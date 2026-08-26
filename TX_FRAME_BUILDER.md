# TX Frame Builder 模块设计约束

## 1. 模块定位

TX Frame Builder 位于 `Response Buffer` 与 UART TX 模块之间，负责缓存响应 Payload 并生成完整发送帧。

职责：

- 内部提供 Response RAM，缓存当前响应 Payload；
- 接收 `Response Buffer` 输出的统一响应接口；
- 沿用当前请求的 ADDR、CMD、SEQ 生成响应帧；
- 按通信协议生成 SOF、ADDR、CMD、SEQ、LENGTH、PAYLOAD、CRC；
- 发送过程中同步累计 CRC，不对 Payload 进行二次扫描；
- 通过 `tx_byte` / `tx_valid` / `tx_ready` 与 UART TX 模块逐字节握手；
- 最后一个 CRC 字节成功提交给 UART TX 后产生 `tx_done`。
- 负责 485 方向切换，发送前将方向设置为发送，等待必要的时间后开始发送，结束后等待所有 bit 全部发完，在 delay 一段时间后将方向设置为接收。

TX Frame Builder 不解析具体业务含义，也不区分正常响应和错误响应。

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

当前请求元信息：

```text
req_addr
req_cmd
req_seq
```

响应帧直接沿用当前请求的 ADDR、CMD、SEQ，业务模块和 Error Response Generator 不自行修改这些字段。

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

- 响应源必须先完成全部 Payload 写入，再产生 `rsp_valid`；
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

CRC 的具体算法参数后续在 `COMMUNICATION_PROTOCOL.md` 中统一确定。

---

## 6. tx_done 定义

`tx_done` 在最后一个 CRC 字节完成一次 `tx_valid && tx_ready` 握手后产生。

其含义是：完整响应帧已经全部提交给 UART TX 模块，不要求等待串口线上最后一个停止位实际移出。

当前系统采用严格一问一答模式，`tx_done` 用于结束当前事务并通知 `Frame Parser` 恢复下一帧接收。

---

## 7. 与其他模块的边界

`Response Buffer` 负责将当前正常业务响应或错误响应 MUX 成统一响应接口。

Response Buffer 不包含 Response RAM，也不负责帧生成、CRC、UART TX 握手或等待 `tx_done`。

正常响应与错误响应进入 TX Frame Builder 后完全一致，统一使用同一 Response RAM、帧生成和发送流程。

---

## 8. 设计原则总结

1. Response RAM 放在 TX Frame Builder 内部。
2. 响应源只负责写响应 Payload 并提交 `rsp_valid`。
3. Response Buffer 只负责响应接口 MUX。
4. 响应 ADDR、CMD、SEQ 统一沿用当前请求。
5. TX Frame Builder 统一负责帧格式和流式 CRC。
6. UART TX 采用 `tx_valid` / `tx_ready` 逐字节握手。
7. 最后一个 CRC 字节被 UART TX 接收后即产生 `tx_done`。
