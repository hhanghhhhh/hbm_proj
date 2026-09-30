`timescale 1ns/1ps

/*
 * 模块说明
 *
 * 功能：
 * - 例化 System Controller、Config Manager、Power Sequence Engine、Alarm Handler。
 * - 在顶层完成 sel_id 业务命令 MUX，并按 BUS_ID 路由到 8 个 AD5560 Driver。
 * - 例化 8 个 Driver；每个 Driver 内部包含 1 个 SPI Master，控制 16 颗 AD5560。
 *
 * 关键约束：
 * - MUX / BUS Route 逻辑较薄，直接保留在 Top，不单独拆模块。
 * - Driver ready 向量同时供 Config/PSE 调度和 System Controller fault reset 使用。
 * - 当前只有 Alarm Handler 使用 READ response，因此 8 路 rsp 在 Top 汇总后送回 Alarm Handler。
 * - ALARM 为板级异步输入，在 Top 内两拍同步后送 System Controller。
 */

module ad5560_top #(
    parameter SYS_CLK_FREQ    = 100_000_000,
    parameter SPI_CLK_FREQ    = 10_000_000,
    parameter BUSY_TIMEOUT_US = 5
)(
    input  wire         i_clk,
    input  wire         i_rst_n,

    // Host -> Config RAM
    input  wire         i_cfg_ram_wr_en,
    input  wire [9:0]   i_cfg_ram_wr_addr,
    input  wire [31:0]  i_cfg_ram_wr_data,
    input  wire [10:0]  i_cfg_record_count,
    input  wire [15:0]  i_cfg_expected_crc,
    input  wire         i_cfg_crc_start,

    // Host -> Power Sequence RAM
    input  wire         i_seq_ram_wr_en,
    input  wire [10:0]  i_seq_ram_wr_addr,
    input  wire [15:0]  i_seq_ram_wr_data,

    // Host / command control
    input  wire         i_cfg_start_req,
    input  wire         i_seq_start_req,
    input  wire         i_seq_mode,
    input  wire         i_alarm_clear_req,
    input  wire         i_alarm_clear_all,
    input  wire         i_fault_reset,

    // Alarm Result RAM read interface
    input  wire [8:0]   i_alarm_result_rd_addr,
    output wire [15:0]  o_alarm_result_rd_data,

    // Status
    output wire         o_cfg_busy,
    output wire         o_cfg_done,
    output wire         o_cfg_error,
    output wire         o_cfg_crc_done,
    output wire         o_cfg_crc_ok,
    output wire         o_seq_busy,
    output wire         o_seq_done,
    output wire         o_alarm_busy,
    output wire         o_alarm_done,
    output wire         o_alarm_clear_busy,
    output wire         o_alarm_clear_done,
    output wire [127:0] o_device_fault_vector,
    output wire [7:0]   o_fault_vector_latched,
    output wire [1:0]   o_sel_id,

    // AD5560 physical interface
    input  wire [7:0]   i_alarm,
    input  wire [7:0]   i_busy_n,
    input  wire [7:0]   i_spi_miso,
    output wire [7:0]   o_spi_sck,
    output wire [7:0]   o_spi_mosi,
    output wire [127:0] o_sync_n
);

//-------------------------------------------------------------------
// sel_id 编码必须与 System Controller 保持一致，Top 只按该值选择唯一业务命令源。
//-------------------------------------------------------------------
localparam [1:0] SEL_NONE     = 2'd0;
localparam [1:0] SEL_CONFIG   = 2'd1;
localparam [1:0] SEL_SEQUENCE = 2'd2;
localparam [1:0] SEL_ALARM    = 2'd3;

//-------------------------------------------------------------------
// 板级 ALARM 为异步输入；先两拍同步到 i_clk 域，再交给 System Controller 做抢占判断。
//-------------------------------------------------------------------
reg [7:0] alarm_meta;
reg [7:0] alarm_sync;

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        alarm_meta <= 8'd0;
        alarm_sync <= 8'd0;
    end
    else begin
        alarm_meta <= i_alarm;
        alarm_sync <= alarm_meta;
    end
end

//-------------------------------------------------------------------
// System Controller control signals
//-------------------------------------------------------------------
wire        cfg_start;
wire        cfg_abort;
wire        seq_start;
wire        seq_mode;
wire        seq_abort;
wire        alarm_start;
wire [7:0]  alarm_vector;
wire        alarm_abort;
wire        alarm_clear_start;
wire        alarm_clear_all;
wire [7:0]  driver_fault_clear;

wire [7:0]  driver_ready;
wire [7:0]  driver_bus_fault;

//-------------------------------------------------------------------
// Config Manager command source
//-------------------------------------------------------------------
wire        cfg_cmd_valid;
wire        cfg_cmd_ready;
wire        cfg_cmd_rw;
wire [2:0]  cfg_cmd_bus_id;
wire [3:0]  cfg_cmd_device_id;
wire [6:0]  cfg_cmd_reg_addr;
wire [15:0] cfg_cmd_wr_data;

//-------------------------------------------------------------------
// Power Sequence Engine command source
//-------------------------------------------------------------------
wire        seq_cmd_valid;
wire        seq_cmd_ready;
wire        seq_cmd_rw;
wire [2:0]  seq_cmd_bus_id;
wire [3:0]  seq_cmd_device_id;
wire [6:0]  seq_cmd_reg_addr;
wire [15:0] seq_cmd_wr_data;

//-------------------------------------------------------------------
// Alarm Handler command / response
//-------------------------------------------------------------------
wire        alarm_cmd_valid;
wire        alarm_cmd_ready;
wire        alarm_cmd_rw;
wire [2:0]  alarm_cmd_bus_id;
wire [3:0]  alarm_cmd_device_id;
wire [6:0]  alarm_cmd_reg_addr;
wire [15:0] alarm_cmd_wr_data;
reg         alarm_rsp_valid;
reg  [15:0] alarm_rsp_rd_data;

//-------------------------------------------------------------------
// sel_id MUX 输出的公共命令；随后只根据 cmd_bus_id 路由到目标 Driver。
//-------------------------------------------------------------------
reg         common_cmd_valid;
reg         common_cmd_rw;
reg  [2:0]  common_cmd_bus_id;
reg  [3:0]  common_cmd_device_id;
reg  [6:0]  common_cmd_reg_addr;
reg  [15:0] common_cmd_wr_data;
wire        common_cmd_ready;
//-------------------------------------------------------------------
// 8 路 Driver 各自独立返回 ready/fault/rsp；ready 还同时参与 PSE 调度和系统 fault reset 屏障。
//-------------------------------------------------------------------
wire [7:0]   driver_rsp_valid;
wire [127:0] driver_rsp_data;

// 当前业务模块看到的 ready 只来自本条命令指定的 BUS；未被 sel_id 选中的业务模块 ready 强制为 0。
assign common_cmd_ready = driver_ready[common_cmd_bus_id];
assign cfg_cmd_ready     = (o_sel_id == SEL_CONFIG)   ? common_cmd_ready : 1'b0;
assign seq_cmd_ready     = (o_sel_id == SEL_SEQUENCE) ? common_cmd_ready : 1'b0;
assign alarm_cmd_ready   = (o_sel_id == SEL_ALARM)    ? common_cmd_ready : 1'b0;

//-------------------------------------------------------------------
// 业务 MUX：sel_id 只允许 Config / PSE / Alarm 中一个模块驱动 common_cmd_*，不在这里做 BUS 仲裁。
//-------------------------------------------------------------------
always @(*) begin
    common_cmd_valid     = 1'b0;
    common_cmd_rw        = 1'b0;
    common_cmd_bus_id    = 3'd0;
    common_cmd_device_id = 4'd0;
    common_cmd_reg_addr  = 7'd0;
    common_cmd_wr_data   = 16'd0;

    case (o_sel_id)
        SEL_CONFIG: begin
            common_cmd_valid     = cfg_cmd_valid;
            common_cmd_rw        = cfg_cmd_rw;
            common_cmd_bus_id    = cfg_cmd_bus_id;
            common_cmd_device_id = cfg_cmd_device_id;
            common_cmd_reg_addr  = cfg_cmd_reg_addr;
            common_cmd_wr_data   = cfg_cmd_wr_data;
        end
        SEL_SEQUENCE: begin
            common_cmd_valid     = seq_cmd_valid;
            common_cmd_rw        = seq_cmd_rw;
            common_cmd_bus_id    = seq_cmd_bus_id;
            common_cmd_device_id = seq_cmd_device_id;
            common_cmd_reg_addr  = seq_cmd_reg_addr;
            common_cmd_wr_data   = seq_cmd_wr_data;
        end

        SEL_ALARM: begin
            common_cmd_valid     = alarm_cmd_valid;
            common_cmd_rw        = alarm_cmd_rw;
            common_cmd_bus_id    = alarm_cmd_bus_id;
            common_cmd_device_id = alarm_cmd_device_id;
            common_cmd_reg_addr  = alarm_cmd_reg_addr;
            common_cmd_wr_data   = alarm_cmd_wr_data;
        end

        default: ;
    endcase
end

//-------------------------------------------------------------------
// READ response 汇总：当前只有 Alarm Handler 发 READ，且保证一次只有一笔 outstanding READ。
//-------------------------------------------------------------------
integer rsp_i;
always @(*) begin
    alarm_rsp_valid   = 1'b0;
    alarm_rsp_rd_data = 16'd0;

    // 因此正常情况下最多一路 rsp_valid；命中的 BUS 数据直接回送 Alarm Handler。
    for (rsp_i = 0; rsp_i < 8; rsp_i = rsp_i + 1) begin
        if (driver_rsp_valid[rsp_i]) begin
            alarm_rsp_valid   = 1'b1;
            alarm_rsp_rd_data = driver_rsp_data[rsp_i*16 +: 16];
        end
    end
end

//-------------------------------------------------------------------
// System Controller
//-------------------------------------------------------------------
system_controller u_system_controller (
    .i_clk                  (i_clk),
    .i_rst_n                (i_rst_n),
    .i_cfg_start_req        (i_cfg_start_req),
    .i_seq_start_req        (i_seq_start_req),
    .i_seq_mode             (i_seq_mode),
    .i_alarm_clear_req      (i_alarm_clear_req),
    .i_alarm_clear_all      (i_alarm_clear_all),
    .i_fault_reset          (i_fault_reset),
    .i_cfg_done             (o_cfg_done),
    .i_seq_done             (o_seq_done),
    .i_alarm_done           (o_alarm_done),
    .i_alarm_clear_done     (o_alarm_clear_done),
    .i_alarm                (alarm_sync),
    .i_driver_bus_fault     (driver_bus_fault),
    .i_driver_ready         (driver_ready),
    .o_sel_id               (o_sel_id),
    .o_cfg_start            (cfg_start),
    .o_cfg_abort            (cfg_abort),
    .o_seq_start            (seq_start),
    .o_seq_mode             (seq_mode),
    .o_seq_abort            (seq_abort),
    .o_alarm_start          (alarm_start),
    .o_alarm_vector         (alarm_vector),
    .o_alarm_abort          (alarm_abort),
    .o_alarm_clear_start    (alarm_clear_start),
    .o_alarm_clear_all      (alarm_clear_all),
    .o_driver_fault_clear   (driver_fault_clear),
    .o_fault_vector_latched (o_fault_vector_latched)
);

//-------------------------------------------------------------------
// Config Manager
//-------------------------------------------------------------------
config_manager u_config_manager (
    .i_clk              (i_clk),
    .i_rst_n            (i_rst_n),
    .i_cfg_ram_wr_en    (i_cfg_ram_wr_en),
    .i_cfg_ram_wr_addr  (i_cfg_ram_wr_addr),
    .i_cfg_ram_wr_data  (i_cfg_ram_wr_data),
    .i_cfg_record_count (i_cfg_record_count),
    .i_cfg_expected_crc (i_cfg_expected_crc),
    .i_cfg_crc_start    (i_cfg_crc_start),
    .o_cfg_crc_done     (o_cfg_crc_done),
    .o_cfg_crc_ok       (o_cfg_crc_ok),
    .i_cfg_start        (cfg_start),
    .i_cfg_abort        (cfg_abort),
    .o_cfg_busy         (o_cfg_busy),
    .o_cfg_done         (o_cfg_done),
    .o_cfg_error        (o_cfg_error),
    .i_cfg_bus_ready    (driver_ready),
    .o_cmd_valid        (cfg_cmd_valid),
    .i_cmd_ready        (cfg_cmd_ready),
    .o_cmd_rw           (cfg_cmd_rw),
    .o_cmd_bus_id       (cfg_cmd_bus_id),
    .o_cmd_device_id    (cfg_cmd_device_id),
    .o_cmd_reg_addr     (cfg_cmd_reg_addr),
    .o_cmd_wr_data      (cfg_cmd_wr_data)
);

//-------------------------------------------------------------------
// Power Sequence Engine
//-------------------------------------------------------------------
power_sequence_engine #(
    .SYS_CLK_FREQ (SYS_CLK_FREQ)
) u_power_sequence_engine (
    .i_clk             (i_clk),
    .i_rst_n           (i_rst_n),
    .i_seq_ram_wr_en   (i_seq_ram_wr_en),
    .i_seq_ram_wr_addr (i_seq_ram_wr_addr),
    .i_seq_ram_wr_data (i_seq_ram_wr_data),
    .i_seq_start       (seq_start),
    .i_seq_mode        (seq_mode),
    .i_seq_abort       (seq_abort),
    .o_seq_busy        (o_seq_busy),
    .o_seq_done        (o_seq_done),
    .i_seq_bus_ready   (driver_ready),
    .o_cmd_valid       (seq_cmd_valid),
    .i_cmd_ready       (seq_cmd_ready),
    .o_cmd_rw          (seq_cmd_rw),
    .o_cmd_bus_id      (seq_cmd_bus_id),
    .o_cmd_device_id   (seq_cmd_device_id),
    .o_cmd_reg_addr    (seq_cmd_reg_addr),
    .o_cmd_wr_data     (seq_cmd_wr_data)
);

//-------------------------------------------------------------------
// Alarm Handler
//-------------------------------------------------------------------
alarm_handler u_alarm_handler (
    .i_clk                  (i_clk),
    .i_rst_n                (i_rst_n),
    .i_alarm_start          (alarm_start),
    .i_alarm_vector         (alarm_vector),
    .i_alarm_abort          (alarm_abort),
    .i_alarm_clear_start    (alarm_clear_start),
    .i_alarm_clear_all      (alarm_clear_all),
    .o_alarm_busy           (o_alarm_busy),
    .o_alarm_done           (o_alarm_done),
    .o_alarm_clear_busy     (o_alarm_clear_busy),
    .o_alarm_clear_done     (o_alarm_clear_done),
    .o_device_fault_vector  (o_device_fault_vector),
    .i_alarm_result_rd_addr (i_alarm_result_rd_addr),
    .o_alarm_result_rd_data (o_alarm_result_rd_data),
    .o_cmd_valid            (alarm_cmd_valid),
    .i_cmd_ready            (alarm_cmd_ready),
    .o_cmd_rw               (alarm_cmd_rw),
    .o_cmd_bus_id           (alarm_cmd_bus_id),
    .o_cmd_device_id        (alarm_cmd_device_id),
    .o_cmd_reg_addr         (alarm_cmd_reg_addr),
    .o_cmd_wr_data          (alarm_cmd_wr_data),
    .i_rsp_valid            (alarm_rsp_valid),
    .i_rsp_rd_data          (alarm_rsp_rd_data)
);

//-------------------------------------------------------------------
// 8 路 BUS 路由：命令字段广播到所有 Driver，只有 BUS_ID 匹配实例的 cmd_valid 被拉高。
//-------------------------------------------------------------------
genvar bus_i;
generate
    for (bus_i = 0; bus_i < 8; bus_i = bus_i + 1) begin : GEN_AD5560_BUS
        localparam [2:0] BUS_ID = bus_i;
        wire bus_cmd_valid;

        // 每个 Driver 的 BUS_ID 在 generate 时固定；valid 是唯一的目标选择条件。
        assign bus_cmd_valid = common_cmd_valid &&
                               (common_cmd_bus_id == BUS_ID);

        ad5560_driver #(
            .SYS_CLK_FREQ    (SYS_CLK_FREQ),
            .SPI_CLK_FREQ    (SPI_CLK_FREQ),
            .BUSY_TIMEOUT_US (BUSY_TIMEOUT_US)
        ) u_ad5560_driver (
            .i_clk             (i_clk),
            .i_rst_n           (i_rst_n),
            .i_cmd_valid       (bus_cmd_valid),
            .o_cmd_ready       (driver_ready[bus_i]),
            .i_cmd_rw          (common_cmd_rw),
            .i_cmd_device_id   (common_cmd_device_id),
            .i_cmd_reg_addr    (common_cmd_reg_addr),
            .i_cmd_wr_data     (common_cmd_wr_data),
            .o_rsp_valid       (driver_rsp_valid[bus_i]),
            .o_rsp_rd_data     (driver_rsp_data[bus_i*16 +: 16]),
            .o_bus_fault       (driver_bus_fault[bus_i]),
            .i_bus_fault_clear (driver_fault_clear[bus_i]),
            .o_sync_n          (o_sync_n[bus_i*16 +: 16]),
            .i_busy_n          (i_busy_n[bus_i]),
            .o_spi_sck         (o_spi_sck[bus_i]),
            .o_spi_mosi        (o_spi_mosi[bus_i]),
            .i_spi_miso        (i_spi_miso[bus_i])
        );
    end
endgenerate

endmodule
