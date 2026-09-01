`timescale 1ns / 1ps

/*
 * Module Contract
 *
 * 模块职责：
 * - 组合一份 config_application 和 BUS_COUNT 份独立单总线执行单元。
 * - 按 application 给出的 BUS 选择路由配置 RAM、启动、结果和遥测 RAM 接口。
 * - 不负责：新增协议解析、任务排队、跨总线仲裁或取消已启动的 I2C 任务。
 *
 * 输入事务：
 * - 配置请求接口原样交给 config_application；该模块解析 Payload 首字节选择 BUS。
 * - 公共配置数据和参数广播到所有总线，但写、启动和结果读使能只送往选中总线。
 * - 遥测读请求用 i_tel_rd_bus 独立选通一路，不依赖当前配置 BUS。
 *
 * 输出事务：
 * - 配置响应和错误接口直接来自 config_application。
 * - 各总线任务结果按 BUS0 位于最低位的规则打包输出，不做再编码或锁存。
 * - o_tel_rd_data 返回发出同步读请求时所选 BUS 的 32 位原始 RAM 数据。
 *
 * 关键时序：
 * - 配置 ready 和结果数据均组合选择当前 bus_sel 对应总线。
 * - i_tel_rd_en 有效沿锁存 i_tel_rd_bus，返回阶段无需上游继续保持 BUS。
 * - 模块不为 RAM 固有同步读延迟增加额外等待周期。
 *
 * 异常与恢复：
 * - reset：异步低有效，仅将遥测返回 BUS 选择清零；子模块分别执行自身复位。
 * - abort：只传给 config_application，取消通信侧事务，不清除各总线 RAM 或后台任务。
 *
 * 使用约束：
 * - BUS_COUNT 必须为 1..8；所有接口必须位于 i_clk 时钟域。
 * - 上层不得在某总线执行配置期间覆盖其配置 RAM或对该总线重复启动。
 * - i_cfg_ok 固定为 8 位，bit[n]=1 表示 BUSn 正常。
 *
 * 参考：
 * - DUT_POWER_CONTROL_FLOW.md：多总线配置和遥测数据流。
 */
module config_subsystem #(
    parameter integer BUS_COUNT = 8,
    parameter integer CLK_FREQ_HZ = 100000000,
    parameter integer I2C_BAUD_RATE = 400000,
    parameter         TCA_ENABLE = 1'b0,
    parameter [6:0]   JWH_ADDR_BASE = 7'h60
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,
    input  wire        i_req_valid,
    input  wire [7:0]  i_req_cmd,
    input  wire [7:0]  i_req_seq,
    input  wire [15:0] i_req_length,
    output wire [10:0] o_payload_rd_addr,
    input  wire [7:0]  i_payload_rd_data,

    output wire        o_rsp_wr_en,
    output wire [10:0] o_rsp_wr_addr,
    output wire [7:0]  o_rsp_wr_data,
    output wire [15:0] o_rsp_length,
    output wire        o_rsp_valid,
    output wire        o_error_valid,
    output wire [7:0]  o_error_code,

    input  wire [BUS_COUNT-1:0] i_config_allowed,
    input  wire [127:0] i_telemetry_enable,
    input  wire [7:0]  i_cfg_ok,
    input  wire [2:0]  i_tel_rd_bus,
    input  wire        i_tel_rd_en,
    input  wire [8:0]  i_tel_rd_addr,
    output wire [31:0] o_tel_rd_data,
    output wire [BUS_COUNT-1:0] o_cfg_resp_valid,
    output wire [BUS_COUNT-1:0] o_cfg_resp_error,
    output wire [BUS_COUNT*4-1:0] o_cfg_sys_error_code,
    output wire [BUS_COUNT*5-1:0] o_cfg_bus_error_code,
    output wire [BUS_COUNT*10-1:0] o_cfg_error_index,
    output wire [BUS_COUNT*16-1:0] o_cfg_last_mtp_crc,
    inout  wire [BUS_COUNT-1:0] io_i2c_scl,
    inout  wire [BUS_COUNT-1:0] io_i2c_sda
);

    wire [2:0] bus_sel;
    wire cfg_ram_wr_en;
    wire [9:0] cfg_ram_wr_addr;
    wire [31:0] cfg_ram_wr_data;
    wire cfg_start;
    wire [5:0] cfg_device_id;
    wire [10:0] cfg_record_count;
    wire cfg_store_after;
    wire cfg_config_mode;
    wire [BUS_COUNT-1:0] bus_ready;
    wire selected_ready;
    wire [BUS_COUNT*16-1:0] cfg_result_rd_data;
    wire [15:0] selected_cfg_result_rd_data;
    wire cfg_result_rd_en;
    wire [9:0] cfg_result_rd_addr;
    wire [BUS_COUNT*32-1:0] tel_rd_data;
    reg [2:0] tel_rd_bus;

    // 地址/参数是公共数据总线；返回信息只选择当前请求指定的一路。
    assign selected_ready  = bus_ready[bus_sel];
    assign selected_cfg_result_rd_data =
        cfg_result_rd_data[bus_sel*16 +: 16];
    assign o_tel_rd_data = tel_rd_data[tel_rd_bus*32 +: 32];

    // RAM 同步读：锁存发出请求时的 BUS，返回时无需外部继续保持。
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            tel_rd_bus        <= 3'd0;
        end else begin
            if (i_tel_rd_en)
                tel_rd_bus <= i_tel_rd_bus;
        end
    end

    config_application #(
        .BUS_COUNT (BUS_COUNT)
    ) u_config_application (
        .i_clk              (i_clk),
        .i_rst_n            (i_rst_n),
        .i_abort            (i_abort),
        .i_req_valid        (i_req_valid),
        .i_req_cmd          (i_req_cmd),
        .i_req_seq          (i_req_seq),
        .i_req_length       (i_req_length),
        .o_payload_rd_addr  (o_payload_rd_addr),
        .i_payload_rd_data  (i_payload_rd_data),
        .o_rsp_wr_en        (o_rsp_wr_en),
        .o_rsp_wr_addr      (o_rsp_wr_addr),
        .o_rsp_wr_data      (o_rsp_wr_data),
        .o_rsp_length       (o_rsp_length),
        .o_rsp_valid        (o_rsp_valid),
        .o_error_valid      (o_error_valid),
        .o_error_code       (o_error_code),
        .o_bus_sel          (bus_sel),
        .o_cfg_ram_wr_en    (cfg_ram_wr_en),
        .o_cfg_ram_wr_addr  (cfg_ram_wr_addr),
        .o_cfg_ram_wr_data  (cfg_ram_wr_data),
        .o_cfg_start        (cfg_start),
        .i_cfg_ready        (selected_ready),
        .o_cfg_device_id    (cfg_device_id),
        .o_cfg_record_count (cfg_record_count),
        .o_cfg_store_after  (cfg_store_after),
        .o_cfg_config_mode  (cfg_config_mode),
        .o_cfg_result_rd_en (cfg_result_rd_en),
        .o_cfg_result_rd_addr (cfg_result_rd_addr),
        .i_cfg_result_rd_data (selected_cfg_result_rd_data),
        .i_cfg_ok          (i_cfg_ok)
    );

    genvar bus_index;
    generate
        for (bus_index = 0; bus_index < BUS_COUNT; bus_index = bus_index + 1) begin : g_bus
            localparam [2:0] BUS_ID = bus_index;
            wire selected;

            assign selected = (bus_sel == BUS_ID);

            // 每个实例只接收自己的动作脉冲，内部参数和 RAM 各自独立。
            i2c_bus_unit #(
                .CLK_FREQ_HZ  (CLK_FREQ_HZ),
                .I2C_BAUD_RATE (I2C_BAUD_RATE),
                .TCA_ENABLE   (TCA_ENABLE),
                .JWH_ADDR_BASE (JWH_ADDR_BASE)
            ) u_bus (
                .i_clk              (i_clk),
                .i_rst_n            (i_rst_n),
                .i_config_allowed   (i_config_allowed[bus_index]),
                .i_telemetry_enable (
                    i_telemetry_enable[bus_index*16 +: 16]),
                .i_cfg_ram_wr_en    (cfg_ram_wr_en && selected),
                .i_cfg_ram_wr_addr  (cfg_ram_wr_addr),
                .i_cfg_ram_wr_data  (cfg_ram_wr_data),
                .i_cfg_start        (cfg_start && selected),
                .o_cfg_ready        (bus_ready[bus_index]),
                .i_cfg_device_id    (cfg_device_id),
                .i_cfg_record_count (cfg_record_count),
                .i_cfg_store_after  (cfg_store_after),
                .i_cfg_config_mode  (cfg_config_mode),
                .i_cfg_result_rd_en (cfg_result_rd_en && selected),
                .i_cfg_result_rd_addr (cfg_result_rd_addr),
                .o_cfg_result_rd_data (
                    cfg_result_rd_data[bus_index*16 +: 16]),
                .i_tel_rd_en        (i_tel_rd_en &&
                                     (i_tel_rd_bus == BUS_ID)),
                .i_tel_rd_addr      (i_tel_rd_addr),
                .o_tel_rd_data      (tel_rd_data[bus_index*32 +: 32]),
                .o_cfg_resp_valid          (o_cfg_resp_valid[bus_index]),
                .o_cfg_resp_error          (o_cfg_resp_error[bus_index]),
                .o_cfg_sys_error_code      (o_cfg_sys_error_code[bus_index*4 +: 4]),
                .o_cfg_bus_error_code      (o_cfg_bus_error_code[bus_index*5 +: 5]),
                .o_cfg_error_index         (o_cfg_error_index[bus_index*10 +: 10]),
                .o_cfg_last_mtp_crc        (o_cfg_last_mtp_crc[bus_index*16 +: 16]),
                .io_i2c_scl         (io_i2c_scl[bus_index]),
                .io_i2c_sda         (io_i2c_sda[bus_index])
            );
        end
    endgenerate

endmodule
