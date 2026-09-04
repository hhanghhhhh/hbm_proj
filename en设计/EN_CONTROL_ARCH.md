# EN 控制架构

## 1. 当前结构

系统内部按 128 路 EN 组织控制状态，当前 FPGA 顶层实际引出低 112 路。

```text
                         上位机命令
                             |
                             v
                  en_control_application
                    |                   |
                    | 直接 EN 状态      | 时序参数 / 启动
                    v                   v
          debug_en_state[127:0]  en_sequence_controller
                                         |
                                         | 内部 en_seq_ram
                                         v
                              sequence_en_state[127:0]

          debug_en_state[111:0]
                    |
                    v
          o_jwh_power_enable[111:0]
```

## 2. 模块职责

### en_control_application

接收上位机 EN 控制命令，形成两类输出：

- 直接控制：接收 128 位 EN 状态，输出 `debug_en_state[127:0]`；
- 时序控制：写入时序参数，并下发 `sequence_id` 和 `start`。

### en_sequence_controller

内部例化 `en_seq_ram`，保存上位机写入的时序参数。收到启动命令后读取对应时序，生成 `sequence_en_state[127:0]`。

## 3. 当前顶层连接

当前直接控制状态和时序控制状态均已在顶层保留，但尚未进行选择或合并。物理 EN 输出固定使用直接控制状态的低 112 位：

```verilog
assign o_jwh_power_enable = debug_en_state[111:0];
```

因此目前 `sequence_en_state[127:0]` 不影响板级 EN 引脚。

## 4. EN 竞争

可使用 START_SYNC，该信号代表是否生在输出，非正在输出时切到 debug_en