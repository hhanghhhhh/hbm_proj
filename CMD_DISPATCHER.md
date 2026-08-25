# CMD Dispatcher 模块设计约束

## 1. 模块定位

CMD Dispatcher 位于 `Frame Parser` 与业务模块之间。

职责：

- 接收 `Frame Parser` 提交的合法完整帧；
- 根据 `CMD` 选择对应业务模块；
- 管理当前请求从分发到处理完成的生命周期；
- 统一管理 Payload RAM 读接口和业务完成返回；
- 业务处理结束后向 `Frame Parser` 返回 `frame_done`。

CMD Dispatcher 不解析 Payload 的业务含义，不执行具体业务逻辑。

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
```

系统按单事务方式工作：同一时刻只允许一个已接收帧进入业务处理。

---

## 3. CMD 分配原则

CMD 按功能类别划分连续编号区间，高位用于区分业务类别，低位由对应业务模块解释。

CMD Dispatcher 只负责识别 CMD 所属业务模块，不解析模块内部具体命令。

具体 CMD 编号和分类统一在 `CMD_DEFINITION.md` 中定义。

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

---

## 5. Payload RAM 访问

Payload RAM 保持在 `Frame Parser` 内部。

各业务模块仅输出自己的：

```text
payload_rd_addr
```

CMD Dispatcher 根据当前选中的业务模块进行地址 MUX，统一连接到 `Frame Parser` 的 `payload_rd_addr`。

`payload_rd_data` 可广播给所有业务模块。

由于系统同一时刻只处理一个请求，不需要额外 RAM 仲裁机制。

---

## 6. 业务完成接口

每个业务模块提供独立的完成信号：

```text
req_done
```

CMD Dispatcher 仅采纳当前被选中模块的 `req_done`。

业务处理完成后，由 CMD Dispatcher 产生：

```text
frame_done
```

通知 `Frame Parser` 释放当前帧及 Payload RAM。

---

## 7. 扩展原则

新增业务模块时：

- 保持统一请求/完成接口规范；
- 新增对应 `req_valid`、`payload_rd_addr`、`req_done` 接入；
- 在 CMD 分类中增加对应路由；
- 扩展 Payload 地址 MUX 和后续响应 MUX；
- 不修改 `Frame Parser` 基础接口和帧格式。

当业务模块数量较少时保持当前轻量接口，不引入 AXI、Wishbone 等通用总线。

---

## 8. 设计原则总结

1. Dispatcher 只负责路由和请求生命周期管理。
2. CMD 分类与业务模块一一对应，模块内部自行解析具体 CMD。
3. 公共请求信息广播，使用独立 `req_valid` 选通业务模块。
4. Payload RAM 通过 MUX 供当前业务模块读取。
5. 同一时刻只允许一个业务模块处理请求。
6. 业务模块完成后统一由 Dispatcher 释放当前接收帧。
7. 新增业务模块不应影响基础通信协议和 Frame Parser。
