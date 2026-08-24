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

```
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

```
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

注意：

- 不需要等待整帧接收完成后重新解析；
- 接收过程中完成字段解析和 CRC 累计计算；
- Payload 仅在接收过程中写入 RAM；
- CRC 通过后才允许业务模块读取。

---

# 4. 内部 RAM

Frame Parser 内部包含 Payload RAM。

用途：

- 暂存当前完整 Payload 数据；
- 提供统一的数据访问接口给后级解析模块。

设计原则：

- 无论 Payload 长度大小，均通过 RAM 访问；
- Frame Parser 不解析 Payload 内容；
- 后级模块根据 CMD 类型解析 Payload。

例如：

```
CMD_CONFIG_DATA
        |
        v
读取 Payload RAM
        |
        v
配置处理模块
```

---

# 5. 接口设计

## 输入

```
rx_byte
rx_valid
```

表示接收到的串行数据字节。

---

## 输出

帧有效通知：

```
frame_valid
```

表示：

- SOF 正确；
- LENGTH 合法；
- Payload 接收完成；
- CRC 校验通过。

同时输出：

```
cmd
seq
payload_length
```

其中：

- cmd：用于命令分发；
- seq：用于请求和响应匹配；
- payload_length：表示当前 Payload 有效长度。

---

## Payload RAM 读取接口

后级模块通过 RAM 读取 Payload：

```
payload_rd_addr
payload_rd_data
```

Frame Parser 不主动解析 Payload。

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

# 7. 完成握手

建议增加帧处理完成信号：

```
frame_ready
        |
        v
业务模块读取 Payload
        |
        v
frame_done
```

Frame Parser 收到 `frame_done` 后释放当前帧缓存，继续等待下一帧。

---

# 8. 超时机制：
- 接收超时：帧接收过程中数据中断
- 处理超时：frame_valid 后未收到 frame_done
超时后：
- 清理状态机
- 释放缓存
- 返回等待 SOF 状态

# 9. 设计原则总结

1. Frame Parser 只负责通信可靠性，不负责业务。
2. Payload 使用 RAM 缓存，业务模块统一读取。
3. CRC 边接收边计算，避免二次扫描数据。
4. CRC 校验通过后才产生有效帧。
5. CMD、SEQ、LENGTH 作为帧元信息输出。
6. 配置、升级等业务逻辑由后级模块处理。
