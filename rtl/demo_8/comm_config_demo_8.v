`timescale 1ns / 1ps

/*
 * Module Contract
 *
 * 模块职责：
 * - 提供 UART 字节级通信到八路 I2C 配置/遥测子系统的参考集成顶层。
 * - 串联 Parser、Dispatcher、四类业务、错误响应、响应选择和 TX Frame Builder。
 * - 不负责：例化 UART 串行收发器或 PLL、替代 RAM/IP 依赖、持久保存 service 结果。
 *
 * 输入事务：
 * - i_rx_valid 每有效一拍提交一个 UART 接收字节；合法完整请求由 Parser 提交。
 * - 请求按 CMD 类别分发，同一配置请求的 BUS 字段只选择一个 I2C 单元。
 * - i_tx_ready 必须表示 UART 物理发送完全空闲，而不是 FIFO 可继续写入。
 *
 * 输出事务：
 * - 正常或业务错误响应经统一 RAM/组帧链路从 o_tx_byte/o_tx_valid 输出。
 * - o_tx_valid 保持到 i_tx_ready 握手；RS485 方向释放后产生 1clk o_tx_done。
 * - Parser 接收超时、长度、CRC、地址和事务超时分别以诊断脉冲输出。
 * - 各总线 service 结果按 BUS0 位于最低位的规则打包输出。
 *
 * 关键时序：
 * - o_tx_done 回接 Parser 的 i_frame_done，系统在此前保持单事务 busy。
 * - Parser 事务超时广播中止通信链路，但不连接 service 的 i_clear。
 * - service 响应在单总线单元中固定 ready=1；外部若需保留必须在 valid 时锁存。
 *
 * 异常与恢复：
 * - reset：i_rst_n 分发给所有通信与总线子模块，具体外部状态由各模块契约定义。
 * - 接收校验错误只输出诊断，不生成协议错误响应帧。
 * - 事务超时取消通信处理和未完成发送，不取消已经由 I2C service 接收的任务。
 *
 * 使用约束：
 * - BUS_COUNT 必须为 1..8；UART 实际波特率必须与 BAUD_RATE 参数一致。
 * - 同一总线执行任务期间不得覆盖其配置 RAM 或重复启动。
 * - 工程必须提供响应 RAM、三种 JWH RAM、service/controller 及 FPGA IP 依赖。
 *
 * 参考：
 * - FPGA_COMM_ARCH.md：通信链路、模块边界和全局单事务约束。
 * - DUT_POWER_CONTROL_FLOW.md：配置、遥测与后台 I2C 任务关系。
 */
module comm_config_demo_8 #(
    parameter integer BUS_COUNT = 8,
    parameter integer CLK_FREQ_HZ = 100000000,
    parameter integer BAUD_RATE = 460800,
    parameter integer TRANSACTION_TIMEOUT_MS = 1000,
    parameter integer I2C_BAUD_RATE = 400000,
    parameter         TCA_ENABLE = 1'b0,
    parameter [6:0]   JWH_ADDR_BASE = 7'h60
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire [7:0]  i_local_addr,
    input  wire [7:0]  i_rx_byte,
    input  wire        i_rx_valid,
    output wire [7:0]  o_tx_byte,
    output wire        o_tx_valid,
    input  wire        i_tx_ready,
    output wire        o_rs485_tx_en,
    output wire        o_tx_done,

    output wire        o_rx_timeout,
    output wire        o_length_error,
    output wire        o_crc_error,
    output wire        o_addr_error,
    output wire        o_transaction_timeout,

    input  wire [BUS_COUNT-1:0] i_config_allowed,
    input  wire [7:0]  i_cfg_ok,
    output wire [BUS_COUNT-1:0] o_cfg_resp_valid,
    output wire [BUS_COUNT-1:0] o_cfg_resp_error,
    output wire [BUS_COUNT*4-1:0] o_cfg_sys_error_code,
    output wire [BUS_COUNT*5-1:0] o_cfg_bus_error_code,
    output wire [BUS_COUNT*10-1:0] o_cfg_error_index,
    output wire [BUS_COUNT*16-1:0] o_cfg_last_mtp_crc,
    inout  wire [BUS_COUNT-1:0] io_i2c_scl,
    inout  wire [BUS_COUNT-1:0] io_i2c_sda
);

    wire frame_valid;
    wire [7:0] frame_addr;
    wire [7:0] frame_cmd;
    wire [7:0] frame_seq;
    wire [15:0] frame_length;
    wire [10:0] parser_rd_addr;
    wire [7:0] parser_rd_data;
    wire [7:0] req_cmd;
    wire [7:0] req_seq;
    wire [15:0] req_length;
    wire [7:0] payload_rd_data;
    wire [3:0] active_module;
    wire param_req_valid;
    wire [10:0] param_payload_rd_addr;
    wire param_error_valid;
    wire [7:0] param_error_code;
    wire ctrl_req_valid;
    wire [10:0] ctrl_payload_rd_addr;
    wire ctrl_error_valid;
    wire [7:0] ctrl_error_code;
    wire config_req_valid;
    wire [10:0] config_payload_rd_addr;
    wire config_error_valid;
    wire [7:0] config_error_code;
    wire telemetry_req_valid;
    wire [10:0] telemetry_payload_rd_addr;
    wire telemetry_error_valid;
    wire [7:0] telemetry_error_code;
    wire dispatcher_error_valid;
    wire [7:0] dispatcher_error_code;
    wire error_valid;
    wire [7:0] error_code;

    wire        param_rsp_wr_en;
    wire [10:0] param_rsp_wr_addr;
    wire [7:0]  param_rsp_wr_data;
    wire [15:0] param_rsp_length;
    wire        param_rsp_valid;

    wire        ctrl_rsp_wr_en;
    wire [10:0] ctrl_rsp_wr_addr;
    wire [7:0]  ctrl_rsp_wr_data;
    wire [15:0] ctrl_rsp_length;
    wire        ctrl_rsp_valid;

    wire        config_rsp_wr_en;
    wire [10:0] config_rsp_wr_addr;
    wire [7:0]  config_rsp_wr_data;
    wire [15:0] config_rsp_length;
    wire        config_rsp_valid;

    wire        telemetry_rsp_wr_en;
    wire [10:0] telemetry_rsp_wr_addr;
    wire [7:0]  telemetry_rsp_wr_data;
    wire [15:0] telemetry_rsp_length;
    wire        telemetry_rsp_valid;
    wire [127:0] telemetry_enable;
    wire        tel_rd_en;
    wire [2:0]  tel_rd_bus;
    wire [8:0]  tel_rd_addr;
    wire [31:0] tel_rd_data;

    wire        error_rsp_wr_en;
    wire [10:0] error_rsp_wr_addr;
    wire [7:0]  error_rsp_wr_data;
    wire [15:0] error_rsp_length;
    wire        error_rsp_valid;
    wire        rsp_wr_en;
    wire [10:0] rsp_wr_addr;
    wire [7:0]  rsp_wr_data;
    wire [15:0] rsp_length;
    wire        rsp_valid;

    // 接收端只提交完整、校验正确且属于本机的帧。
    frame_parser #(
        .CLK_FREQ_HZ            (CLK_FREQ_HZ),
        .BAUD_RATE              (BAUD_RATE),
        .MAX_PAYLOAD_LENGTH     (2048),
        .TRANSACTION_TIMEOUT_MS (TRANSACTION_TIMEOUT_MS)
    ) u_frame_parser (
        .i_clk                 (i_clk),
        .i_rst_n               (i_rst_n),
        .i_rx_byte             (i_rx_byte),
        .i_rx_valid            (i_rx_valid),
        .i_local_addr          (i_local_addr),
        .i_frame_done          (o_tx_done),
        .o_frame_valid         (frame_valid),
        .o_addr                (frame_addr),
        .o_cmd                 (frame_cmd),
        .o_seq                 (frame_seq),
        .o_payload_length      (frame_length),
        .i_payload_rd_addr     (parser_rd_addr),
        .o_payload_rd_data     (parser_rd_data),
        .o_rx_timeout          (o_rx_timeout),
        .o_length_error        (o_length_error),
        .o_crc_error           (o_crc_error),
        .o_addr_error          (o_addr_error),
        .o_transaction_timeout (o_transaction_timeout)
    );

    // Dispatcher 只增加一个配置类别，不为八条总线增加八组请求端口。
    cmd_dispatcher u_cmd_dispatcher (
        .i_clk                    (i_clk),
        .i_rst_n                  (i_rst_n),
        .i_abort                  (o_transaction_timeout),
        .i_frame_valid            (frame_valid),
        .i_frame_cmd              (frame_cmd),
        .i_frame_seq              (frame_seq),
        .i_frame_length           (frame_length),
        .o_req_cmd                (req_cmd),
        .o_req_seq                (req_seq),
        .o_req_length             (req_length),
        .o_payload_rd_data        (payload_rd_data),
        .o_param_req_valid        (param_req_valid),
        .o_ctrl_req_valid         (ctrl_req_valid),
        .o_config_req_valid       (config_req_valid),
        .o_telemetry_req_valid    (telemetry_req_valid),
        .o_active_module          (active_module),
        .i_param_payload_rd_addr  (param_payload_rd_addr),
        .i_ctrl_payload_rd_addr   (ctrl_payload_rd_addr),
        .i_config_payload_rd_addr (config_payload_rd_addr),
        .i_telemetry_payload_rd_addr (telemetry_payload_rd_addr),
        .o_payload_rd_addr        (parser_rd_addr),
        .i_payload_rd_data        (parser_rd_data),
        .o_error_valid            (dispatcher_error_valid),
        .o_error_code             (dispatcher_error_code)
    );

    // 现有两类 demo 仍保持原接口，与配置类共用 Payload RAM 和响应链路。
    demo_param u_demo_param (
        .i_clk             (i_clk),
        .i_rst_n           (i_rst_n),
        .i_abort           (o_transaction_timeout),
        .i_req_valid       (param_req_valid),
        .i_req_cmd         (req_cmd),
        .i_req_seq         (req_seq),
        .i_req_length      (req_length),
        .o_payload_rd_addr (param_payload_rd_addr),
        .i_payload_rd_data (payload_rd_data),
        .o_rsp_wr_en        (param_rsp_wr_en),
        .o_rsp_wr_addr      (param_rsp_wr_addr),
        .o_rsp_wr_data      (param_rsp_wr_data),
        .o_rsp_length       (param_rsp_length),
        .o_rsp_valid        (param_rsp_valid),
        .o_error_valid     (param_error_valid),
        .o_error_code      (param_error_code),
        .o_demo_param      ()
    );

    demo_ctrl u_demo_ctrl (
        .i_clk             (i_clk),
        .i_rst_n           (i_rst_n),
        .i_abort           (o_transaction_timeout),
        .i_req_valid       (ctrl_req_valid),
        .i_req_cmd         (req_cmd),
        .i_req_seq         (req_seq),
        .i_req_length      (req_length),
        .o_payload_rd_addr (ctrl_payload_rd_addr),
        .i_payload_rd_data (payload_rd_data),
        .o_rsp_wr_en        (ctrl_rsp_wr_en),
        .o_rsp_wr_addr      (ctrl_rsp_wr_addr),
        .o_rsp_wr_data      (ctrl_rsp_wr_data),
        .o_rsp_length       (ctrl_rsp_length),
        .o_rsp_valid        (ctrl_rsp_valid),
        .o_error_valid     (ctrl_error_valid),
        .o_error_code      (ctrl_error_code),
        .o_demo_enable      ()
    );

    // 遥测业务保存 128 位使能并读取各总线单元内的遥测 RAM。
    telemetry_application u_telemetry_application (
        .i_clk                  (i_clk),
        .i_rst_n                (i_rst_n),
        .i_abort                (o_transaction_timeout),
        .i_req_valid            (telemetry_req_valid),
        .i_req_cmd              (req_cmd),
        .i_req_seq              (req_seq),
        .i_req_length           (req_length),
        .o_payload_rd_addr      (telemetry_payload_rd_addr),
        .i_payload_rd_data      (payload_rd_data),
        .o_rsp_wr_en            (telemetry_rsp_wr_en),
        .o_rsp_wr_addr          (telemetry_rsp_wr_addr),
        .o_rsp_wr_data          (telemetry_rsp_wr_data),
        .o_rsp_length           (telemetry_rsp_length),
        .o_rsp_valid            (telemetry_rsp_valid),
        .o_error_valid          (telemetry_error_valid),
        .o_error_code           (telemetry_error_code),
        .o_telemetry_enable     (telemetry_enable),
        .o_tel_rd_en            (tel_rd_en),
        .o_tel_rd_bus           (tel_rd_bus),
        .o_tel_rd_addr          (tel_rd_addr),
        .i_tel_rd_data          (tel_rd_data)
    );

    config_subsystem #(
        .BUS_COUNT     (BUS_COUNT),
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .I2C_BAUD_RATE (I2C_BAUD_RATE),
        .TCA_ENABLE    (TCA_ENABLE),
        .JWH_ADDR_BASE (JWH_ADDR_BASE)
    ) u_config_subsystem (
        .i_clk             (i_clk),
        .i_rst_n           (i_rst_n),
        .i_abort           (o_transaction_timeout),
        .i_req_valid       (config_req_valid),
        .i_req_cmd         (req_cmd),
        .i_req_seq         (req_seq),
        .i_req_length      (req_length),
        .o_payload_rd_addr (config_payload_rd_addr),
        .i_payload_rd_data (payload_rd_data),
        .o_rsp_wr_en        (config_rsp_wr_en),
        .o_rsp_wr_addr      (config_rsp_wr_addr),
        .o_rsp_wr_data      (config_rsp_wr_data),
        .o_rsp_length       (config_rsp_length),
        .o_rsp_valid        (config_rsp_valid),
        .o_error_valid     (config_error_valid),
        .o_error_code      (config_error_code),
        .i_config_allowed  (i_config_allowed),
        .i_telemetry_enable (telemetry_enable),
        .i_cfg_ok          (i_cfg_ok),
        .i_tel_rd_bus         (tel_rd_bus),
        .i_tel_rd_en          (tel_rd_en),
        .i_tel_rd_addr        (tel_rd_addr),
        .o_tel_rd_data        (tel_rd_data),
        .o_cfg_resp_valid          (o_cfg_resp_valid),
        .o_cfg_resp_error          (o_cfg_resp_error),
        .o_cfg_sys_error_code      (o_cfg_sys_error_code),
        .o_cfg_bus_error_code      (o_cfg_bus_error_code),
        .o_cfg_error_index         (o_cfg_error_index),
        .o_cfg_last_mtp_crc        (o_cfg_last_mtp_crc),
        .io_i2c_scl        (io_i2c_scl),
        .io_i2c_sda        (io_i2c_sda)
    );

    // 单事务下各错误源互斥；只选择错误码，不加排队或额外仲裁状态机。
    assign error_valid = dispatcher_error_valid || param_error_valid ||
                         ctrl_error_valid || config_error_valid ||
                         telemetry_error_valid;
    assign error_code = dispatcher_error_valid ? dispatcher_error_code :
                        param_error_valid ? param_error_code :
                        ctrl_error_valid ? ctrl_error_code :
                        config_error_valid ? config_error_code :
                        telemetry_error_code;

    error_response_generator u_error_response (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_abort       (o_transaction_timeout),
        .i_error_valid (error_valid),
        .i_error_code  (error_code),
        .o_rsp_wr_en        (error_rsp_wr_en),
        .o_rsp_wr_addr      (error_rsp_wr_addr),
        .o_rsp_wr_data      (error_rsp_wr_data),
        .o_rsp_length       (error_rsp_length),
        .o_rsp_valid        (error_rsp_valid)
    );

    // 配置仍只有一个正常响应源，BUS 的选择不进入响应 MUX。
    response_buffer u_response_buffer (
        .i_active_module (active_module),
        .i_param_rsp_wr_en        (param_rsp_wr_en),
        .i_param_rsp_wr_addr      (param_rsp_wr_addr),
        .i_param_rsp_wr_data      (param_rsp_wr_data),
        .i_param_rsp_length       (param_rsp_length),
        .i_param_rsp_valid        (param_rsp_valid),
        .i_ctrl_rsp_wr_en        (ctrl_rsp_wr_en),
        .i_ctrl_rsp_wr_addr      (ctrl_rsp_wr_addr),
        .i_ctrl_rsp_wr_data      (ctrl_rsp_wr_data),
        .i_ctrl_rsp_length       (ctrl_rsp_length),
        .i_ctrl_rsp_valid        (ctrl_rsp_valid),
        .i_config_rsp_wr_en        (config_rsp_wr_en),
        .i_config_rsp_wr_addr      (config_rsp_wr_addr),
        .i_config_rsp_wr_data      (config_rsp_wr_data),
        .i_config_rsp_length       (config_rsp_length),
        .i_config_rsp_valid        (config_rsp_valid),
        .i_telemetry_rsp_wr_en     (telemetry_rsp_wr_en),
        .i_telemetry_rsp_wr_addr   (telemetry_rsp_wr_addr),
        .i_telemetry_rsp_wr_data   (telemetry_rsp_wr_data),
        .i_telemetry_rsp_length    (telemetry_rsp_length),
        .i_telemetry_rsp_valid     (telemetry_rsp_valid),
        .i_error_rsp_wr_en        (error_rsp_wr_en),
        .i_error_rsp_wr_addr      (error_rsp_wr_addr),
        .i_error_rsp_wr_data      (error_rsp_wr_data),
        .i_error_rsp_length       (error_rsp_length),
        .i_error_rsp_valid        (error_rsp_valid),
        .o_rsp_wr_en        (rsp_wr_en),
        .o_rsp_wr_addr      (rsp_wr_addr),
        .o_rsp_wr_data      (rsp_wr_data),
        .o_rsp_length       (rsp_length),
        .o_rsp_valid        (rsp_valid)
    );

    tx_frame_builder #(
        .CLK_FREQ_HZ         (CLK_FREQ_HZ),
        .RS485_PRE_DELAY_US  (10),
        .RS485_POST_DELAY_US (10)
    ) u_tx_frame_builder (
        .i_clk          (i_clk),
        .i_rst_n        (i_rst_n),
        .i_abort        (o_transaction_timeout),
        .i_rsp_wr_en        (rsp_wr_en),
        .i_rsp_wr_addr      (rsp_wr_addr),
        .i_rsp_wr_data      (rsp_wr_data),
        .i_rsp_length       (rsp_length),
        .i_rsp_valid        (rsp_valid),
        .i_req_addr     (frame_addr),
        .i_req_cmd      (frame_cmd),
        .i_req_seq      (frame_seq),
        .o_tx_byte      (o_tx_byte),
        .o_tx_valid     (o_tx_valid),
        .i_tx_ready     (i_tx_ready),
        .o_rs485_tx_en  (o_rs485_tx_en),
        .o_tx_done      (o_tx_done)
    );

endmodule
