# Error Response Generator 模块设计约束

## 1. 模块定位

Error Response Generator 用于对“通信帧本身合法，但请求无法正常执行”的情况生成统一错误响应。

该模块只生成错误响应 Payload，不直接生成 UART 通信帧，不负责 CRC，也不负责发送时序。

---

## 2. 错误处理分层

错误分为两类。

### 2.1 帧本身不可信

包括但不限于：

- SOF 同步失败；
- 接收过程中超时；
- LENGTH 非法；
- CRC 校验失败。

此类错误由 `Frame Parser` 直接丢弃当前帧并重新同步，不生成错误响应。

主机侧通过请求超时处理并决定是否重发。

### 2.2 帧合法但请求无法执行

包括但不限于：

- 未定义 CMD；
- Payload 长度或参数非法；
- 当前设备状态不允许执行；
- 配置、升级等业务流程状态错误。

此类错误通过 Error Response Generator 生成错误响应。

---

## 3. 错误请求来源

`CMD Dispatcher` 在合法完整帧中发现未知或未分配 CMD 时，产生错误请求。

各业务模块在处理合法 CMD 时发现业务错误，可产生统一的错误请求，例如：

```text
error_valid
error_code
```

具体错误码分配后续统一定义，业务模块不自行生成完整错误帧。

---

## 4. 错误响应输出

Error Response Generator 使用与普通业务模块一致的响应接口输出错误 Payload：

```text
rsp_wr_en
rsp_wr_addr
rsp_wr_data
rsp_length
rsp_valid
```

错误响应通过 `Response Buffer` 后继续进入正常发送链路：

```text
Error Response Generator
        |
        v
Response Buffer
        |
        v
TX Frame Builder
        |
        v
UART TX
```

因此正常响应和错误响应共用同一个 `TX Frame Builder`、Response RAM、帧格式和 CRC 处理逻辑。

---

## 5. 请求上下文规则

对于所有正常响应和错误响应：

```text
响应 ADDR = 请求 ADDR
响应 CMD  = 请求 CMD
响应 SEQ  = 请求 SEQ
```

ADDR、CMD、SEQ 由当前请求上下文提供并保持到当前事务结束，业务模块和 Error Response Generator 不自行修改这些字段。

错误响应 Payload 第一字节固定为 STATUS。

格式：

```text
+--------+----------------+
| STATUS | ERROR_INFO     |
+--------+----------------+
```

STATUS 非 0 表示错误。

后续 ERROR_INFO 可用于提供：

- error code
- 参数索引
- 附加诊断信息

具体错误码后续统一定义。

---

## 6. 与 Response Buffer 的关系

Error Response Generator 作为 Response Buffer 的一个特殊响应源接入。

正常情况下 Response Buffer 根据 `active_module` 选择当前业务模块响应；产生错误响应时选择 Error Response Generator 输出。

严格单事务模式下，同一请求只能提交正常响应或错误响应之一，不需要复杂仲裁。

---

## 7. 事务结束

错误响应与正常响应完全使用相同发送流程。

最后一个 CRC 字节成功提交给 UART TX 后，`TX Frame Builder` 产生 `tx_done`，结束当前问答事务并允许 `Frame Parser` 恢复下一帧接收。

---

## 8. 待确认事项

后续仍需统一确定：

- 错误码具体编号及含义；
- 错误 Payload 是否需要除 STATUS 之外的附加信息。

CRC 的具体算法参数暂不在本模块中规定。
