# 八路 I2C 配置连接示例

本目录是工程连接参考，不是独立可运行的 FPGA 工程。原始 I2C service 未修改；
本目录内的 `jwh6374_bus_service_demo_8.v` 是面向八路示例的副本。

## 从哪里看

1. `comm_config_demo_8.v`：完整字节级通信连接，含 Frame Parser、Dispatcher、配置与遥测业务、Response Buffer 和 TX Frame Builder。
2. `config_subsystem.v`：一个 `config_application`，通过 `generate` 例化默认八个 `i2c_bus_unit`；本层主要是组合选择与连线。
3. `i2c_bus_unit.v`：一条总线的三种 RAM 和 bus_service。
4. 上一级 `config_application.v`：四个配置子命令的 Payload 解析和响应组织，不复制八份。

```text
comm_config_demo_8
├── frame_parser
├── cmd_dispatcher
├── demo_param / demo_ctrl
├── telemetry_application
├── config_subsystem
│   ├── config_application ×1
│   └── g_bus[0..7].u_bus
│       ├── jwh_cfg_cmd_ram
│       ├── jwh_cfg_result_ram
│       ├── jwh_telemetry_ram
│       └── jwh6374_bus_service_demo_8
├── error_response_generator
├── response_buffer
└── tx_frame_builder
```

默认 BUS_COUNT=8，支持 1..8。顶层 BUS_COUNT 会传给子系统和 application，不能只改循环上限。

## 当前 Payload 格式

括号表示字节数；多字节字段按大端。BUS 为 0..BUS_COUNT-1，所有配置命令都必须携带 BUS，包括 BUS_COUNT=1 时。

| CMD | 请求 Payload | 成功响应 Payload |
|---|---|---|
| 0x10 CONFIG_DATA | BUS(1), OFFSET(2), DATA(4*N) | STATUS=0 |
| 0x11 CONFIG_START | BUS(1), I2C_ADDR(1), CONFIG_LENGTH(2), STORE_FLASH(1), CONFIG_MODE(1) | STATUS=0，表示启动已握手 |
| 0x12 CONFIG_STATUS | 无 | STATUS=0, OK(1) |
| 0x13 CONFIG_RESULT_READ | BUS(1), OFFSET(2), LENGTH(2) | STATUS=0, DATA(2*LENGTH) |

- CONFIG_DATA 的 OFFSET 和 CONFIG_START 的 CONFIG_LENGTH 都以 32 位配置记录为单位，配置 RAM 共 1024 项。
- DATA 至少一条记录；帧 Payload 上限 2048 字节，因此每包最多 2044 字节 DATA（511 条记录），Payload 总长为 2047。
- I2C_ADDR 低六位直接传入 service 的 device_id；不做地址映射。高位由发送方置零。
- STORE_FLASH、CONFIG_MODE 只传递 bit0。

使用示例（仅为 Payload，不包含帧头等）：

- `CMD=0x12, Payload为空`：一次查询全部 8 条 I2C 总线状态。
- `CMD=0x11, Payload=03 04 00 06 00 01`：BUS3，device_id=4，
  6 条记录，store=0，mode=1。
- `CMD=0x13, Payload=03 00 00 00 06`：从 BUS3 结果 RAM 的
  OFFSET=0 开始回读 6 个 16 位结果。

## 总线选择和参数归属

Dispatcher 只识别配置类别 0x1，不读取 BUS。application 解析首字节并保持 bus_sel。
子系统广播写地址、数据和启动参数，只对目标路放行 RAM 写使能、参数写脉冲和 start。
ready 按 bus_sel 选择；CONFIG_STATUS 不使用 BUS，直接锁存 8 位 i_cfg_ok。

遥测位图由一个 telemetry_application 保存，再按 BUS 切成 8 组 16 位，
直接连接各 bus_service，不从配置结果推导是否使能。

## 状态与外部控制

- 顶层 `i_cfg_ok[7:0]` 分别对应 BUS7～BUS0，bit 为 1 表示对应 I2C 正常。
- 原始 `o_cfg_resp_valid/error/sys_error_code/bus_error_code/error_index/last_mtp_crc` 逐路引出，外部可据此维护对应的 `i_cfg_ok` 状态位。
- service 的响应 ready 固定为 1；不要仅把瞬时 resp_valid 当成可长期查询的完成标志。
- 每个 i2c_bus_unit 内部都实例化配置命令 RAM、配置结果 RAM和遥测 RAM。
- 配置结果 RAM 由 `CONFIG_RESULT_READ` 通过 config_application 读取，
  OFFSET 和 LENGTH 的单位均为一个 16 位结果项。
- 单次结果回读 LENGTH 为 1..1023，且 OFFSET+LENGTH 不得超过 1024；
  每项按高字节、低字节顺序写入响应，完整 RAM 可分两次读取。
- 遥测 RAM 通过 telemetry_application 的内部同步读接口读取，返回 32 位数据。
- 遥测读接口会在 `rd_en` 有效时锁存 BUS，返回数据不要求 BUS 持续保持。
- 结果 RAM 回读期间由 config_application 保持 BUS，直到完整响应数据写完。
- `i_config_allowed` 每路一位，由外部提供；不默认允许在输出开启时执行配置。
- 示例不调查 SMB_ALERT，service 的该输入固定为 8'hFF。TCA_ENABLE 默认 0，与参考直连 top 一致，可按实际工程设置。
- 所有多路打包向量均为 BUS0 在最低位，使用 Verilog-2001 的固定宽度切片。

上位机须保证同一路执行任务期间不覆盖配置 RAM、不重复启动；不引入队列或额外忙检查。
不同总线已经启动的任务可以并行执行。通信事务超时只取消未完成的通信处理，不接 service 的 i_clear。

## UART 边界与工程依赖

comm_config_demo_8 从 UART 字节接口开始，到 UART 字节接口结束。外部需连接 UART_RX_Direct / UART_TX_Direct 或等价接口：

- UART RX 字节和有效脉冲接 i_rx_byte/i_rx_valid。
- o_tx_byte/o_tx_valid 接 UART TX；i_tx_ready 必须是整个串行字节发送期间保持低的物理空闲指示，不能用 FIFO 可写。
- 外部 UART 波特率须设为 460800（或与 BAUD_RATE 同步配置），不能沿用现有 UART 文件中的其他默认波特率。
- PLL、复位释放、RS485 收发器和 I2C 上拉由工程顶层提供。
- TX 完成经停止位和方向后延时后反馈 Parser，保持一问一答。

需加入：

- 本目录四个 .v 文件及上一级 rtl 下使用到的公共模块；include 路径包含上一级 rtl。
- 真正的 ip_ram_uart_rx、ip_ram_uart_tx（2048×8，B 口一拍同步读）。
- 本目录的 `jwh6374_bus_service_demo_8.v`，以及参考工程中的下层依赖和 `jwh6374_common_defs.vh`。
- 参考工程 `al_ip` 下的 `jwh_cfg_cmd_ram`、`jwh_cfg_result_ram`、
  `jwh_telemetry_ram` 三个 RAM IP 及其厂商原语库。

公共 cmd_dispatcher 和 response_buffer 已增加配置及遥测接口；其他顶层的具名例化需同步补接。

本次只做源码与语法/接口检查，不代表功能仿真、综合或下板验证通过。

## 本次检查范围

- Icarus Verilog 使用 Verilog-2005 解析模式（源码保持 Verilog-2001 写法）和 `-Wall -i -t null`，不生成或运行仿真。
- 默认 BUS_COUNT=8，以及 BUS_COUNT=1，两组语法和端口展开检查通过。
- 使用参考工程真实的 service、下层控制模块及三种 RAM 包装源码，没有用空壳替代它们。
- `-i` 仅用于跳过当前未提供的模块。取消该选项后确认缺少的是 `ip_ram_uart_rx`、`ip_ram_uart_tx` 和 `PH1_LOGIC_ERAM`；因此不是完整 IP 库下的工程编译通过。
