# CMD Dispatcher 模块设计约束

## 1. 模块定位

CMD Dispatcher 位于 `Frame Parser` 与业务模块之间。

职责：

- 接收 `Frame Parser` 提交的合法完整帧；
- 根据 `CMD` 选择对应业务模块；
- 输出并保持当前 `active_module`；
- 统一管理 Payload RAM 读地址路由；
- 对未知或未分配 CMD 产生统一错误请求。

CMD Dispatcher 不解析 Payload 的业务含义，不执行具体业务逻辑，也不负责响应发送和 `frame_done`。

---

## 2. 基本架构

```text
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
     +--> 未知 CMD -> Error Response Generator
```

系统按单事务方式工作：同一时刻只允许一个已接收帧进入业务处理。

---

## 3. CMD 分配原则

CMD 按功能类别划分连续编号区间，高位用于区分业务类别，低位由对应业务模块解释。

CMD Dispatcher 只负责识别 CMD 所属业务模块，不解析模块内部具体命令。

具体 CMD 编号和分类统一在 `CMD_DEFINITION.md` 中定义。

对于未知或未分配 CMD，不选通任何业务模块，而是向 Error Response Generator 提交错误请求。

---

## 4. 业务模块统一请求接口

公共请求信息统一广播给各业务模块：

```text
req_cmd
req_seq
req_length
payload_rd_data
```

CMD Dispatcher 仅对被选中的模块产生独立 `req_valid`。

业务模块只有在自身 `req_valid` 有效时才允许处理当前请求。

`active_module` 表示当前请求所属业务模块，并提供给后续 Response Buffer 作为响应接口选择依据。

---

## 5. Payload RAM 访问

Payload RAM 保持在 `Frame Parser` 内部。

各业务模块仅输出自己的：

```text
payload_rd_addr
```

CMD Dispatcher 根据 `active_module` 对地址进行 MUX，统一连接到 `Frame Parser` 的 `payload_rd_addr`。

`payload_rd_data` 可广播给所有业务模块。

由于系统同一时刻只处理一个请求，不需要额外 RAM 仲裁机制。

---

## 6. 错误请求

对于未知或未分配 CMD，Dispatcher 产生统一错误请求，例如：

```text
error_valid
error_code
```

错误响应由 `Error Response Generator` 统一生成，Dispatcher 不直接生成错误 Payload 或完整通信帧。

业务模块内部发现的参数、状态等错误也使用同一错误响应机制，详细约束见 `ERROR_RESPONSE.md`。

---

## 7. 与响应链路的关系

正常业务模块完成处理后，通过统一响应接口向 Response Buffer 提交响应。

CMD Dispatcher 不汇聚业务响应数据，不产生发送控制信号，也不等待发送完成。

当前问答事务由发送链路的 `tx_done` 结束，`Frame Parser` 在此后恢复下一帧接收。

---

## 8. 扩展原则

新增业务模块时：

- 保持统一请求接口规范；
- 新增对应 `req_valid`、`payload_rd_addr` 接入；
- 在 CMD 分类中增加对应路由；
- 扩展 Payload 地址 MUX；
- 将同一个 `active_module` 用于后续响应接口选择；
- 不修改 `Frame Parser` 基础接口和帧格式。

当业务模块数量较少时保持当前轻量接口，不引入 AXI、Wishbone 等通用总线。

---

## 9. 设计原则总结

1. Dispatcher 只负责请求路由和 Payload 读接口选择。
2. CMD 分类与业务模块一一对应，模块内部自行解析具体 CMD。
3. 公共请求信息广播，使用独立 `req_valid` 选通业务模块。
4. Payload RAM 通过 MUX 供当前业务模块读取。
5. `active_module` 作为请求与响应两侧统一的业务模块选择依据。
6. 未知 CMD 进入统一错误响应机制。
7. Dispatcher 不负责响应发送和当前事务结束控制。
