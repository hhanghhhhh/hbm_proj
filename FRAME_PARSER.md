# Frame Parser 模块设计说明

## 1. 模块定位

Frame Parser 是 FPGA 通信协议与业务逻辑之间的隔离层。

主要职责：

- 接收串口字节流；
- 按协议解析数据帧；
- 计算并校验 CRC；
- 将 Payload 数据缓存到内部 RAM；
- 仅在完整帧校验通过后通知后级模块处理。

Frame Parser 不负责解析业务含义，不处理具体 CMD 功能。

---

# 2. 数据帧格式

通信帧格式：

```text
+--------+---------+--------+--------+--------+---------+---------+
| SOF    | ADDR    | CMD    | SEQ    | LENGTH | PAYLOAD | CRC     |
+--------+---------+--------+--------+--------+---------+---------+
| 2 Byte | 1 Byte  | 1 Byte | 1 Byte | 2 Byte | N Byte  | 2 Byte  |
+--------+---------+--------+--------+--------+---------+---------+
```

规则：

- LENGTH 表示 PAYLOAD 数据长度；
- SOF 固定为 `0x55AA`；
- CRC 不包含 SOF；
- 多字节数据采用大端格式；
- 最大 Payload 长度为 2048 Byte。

---

# 3. 接收流程

Frame Parser 采用流式接收方式：

```text
RX Byte
   |
   v
Header解析
   |
   v
Payload接收
   |
   +---- 写入 Payload RAM
   |
   +---- CRC计算
   |
   v
CRC字段接收
   |
   v
CRC校验
   |
   +---- 失败：丢弃当前帧
   |
   +---- 成功：frame_valid
```

约束：

- 接收过程中完成字段解析和 CRC 累计计算，不进行二次扫描；
- Payload 仅在接收过程中写入 RAM；
- CRC 通过后才允许后级读取当前 Payload；
- `frame_valid` 后停止接受新的请求帧，直到当前问答事务结束。

---

# 4. 内部 RAM

Frame Parser 内部包含 Payload RAM。

设计原则：

- 无论 Payload 长度大小，均通过 RAM 访问；
- Frame Parser 不解析 Payload 内容；
- 后级模块根据 CMD 类型解析 Payload；
- 当前事务结束前，Payload RAM 内容保持有效且不被下一帧覆盖。

---

# 5. 接口设计

输入字节流：

```text
rx_byte
rx_valid
```

帧有效及元信息输出：

```text
frame_valid
cmd
seq
payload_length
```

Payload RAM 读取接口：

```text
payload_rd_addr
payload_rd_data
```

当前事务完成输入：

```text
frame_done
```

`frame_done` 由 `TX Frame Builder` 的 `tx_done` 产生或直接映射。

当前定义中，`tx_done` 在响应帧最后一个 CRC 字节完成 `tx_valid && tx_ready` 握手后产生，表示完整响应帧已经全部提交给 UART TX 模块。Frame Parser 此时即可释放当前请求并恢复下一帧接收，不要求等待串口线上最后一个停止位实际发送完成。

---

# 6. 字段处理规则

|字段|处理方式|
|-|-|
|SOF|检测同步，不输出|
|ADDR|用于设备地址判断，可内部过滤|
|CMD|保存并输出，用于命令分发|
|SEQ|保存并输出，用于响应匹配|
|LENGTH|控制 Payload 接收长度，并输出|
|PAYLOAD|写入 RAM|
|CRC|接收并比较|

---

# 7. 单事务约束

当前通信采用严格一问一答模式：

```text
接收请求
   ↓
frame_valid
   ↓
业务处理并生成响应
   ↓
发送响应
   ↓
tx_done / frame_done
   ↓
恢复下一帧接收
```

主机等待完整响应后才发送下一请求，因此当前架构不考虑请求并发或多事务排队。

---

# 8. 超时机制

至少考虑：

- 接收超时：帧接收过程中数据中断；
- 事务超时：`frame_valid` 后长期未收到 `frame_done`。

超时后清理当前状态并返回等待 SOF 状态，具体超时参数由实现确定。

---

# 9. 设计原则总结

1. Frame Parser 只负责可靠收帧，不负责业务。
2. Payload 使用内部 RAM 缓存，业务模块统一读取。
3. CRC 边接收边计算，避免二次扫描数据。
4. CRC 校验通过后才产生 `frame_valid`。
5. CMD、SEQ、LENGTH 作为帧元信息输出。
6. `tx_done` 后释放当前帧并恢复下一次问答。
