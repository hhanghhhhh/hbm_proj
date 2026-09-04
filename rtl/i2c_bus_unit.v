`timescale 1ns / 1ps

/*
 * 模块说明
 *
 * 功能：
 * - 封装一条物理 I2C 总线所需的配置命令 RAM、结果 RAM、遥测 RAM 和
 *   jwh6374_bus_service，并提供通信侧读写接口及开漏引脚连接。
 *
 * 关键数据：
 * - 配置命令 RAM 为 1024x32，结果 RAM 为 1024x16，遥测 RAM 为 512x32。
 * - i_telemetry_enable 的 16 位分别控制本总线 8 个设备的两个 Rail。
 *
 * 关键约束：
 * - 外部必须预先完成 BUS 选择；同一任务执行期间不得覆盖命令 RAM 或重复启动。
 * - io_i2c_scl/io_i2c_sda 为开漏三态连接，必须依赖板级上拉。
 * - 工程必须提供三个真实 RAM IP 以及 service/controller 依赖源码。
 *
 * 特殊行为：
 * - service 响应在内部固定 ready=1，外部需要在 o_cfg_resp_valid 有效时锁存结果。
 * - service 的 clear 固定无效，SMB_ALERT# 固定为无告警；通信侧中止不会取消
 *   已被 service 接收的 I2C 任务。
 */
module i2c_bus_unit #(
    parameter integer CLK_FREQ_HZ = 100000000,
    parameter integer I2C_BAUD_RATE = 400000,
    parameter         TCA_ENABLE = 1'b0,
    parameter [6:0]   JWH_ADDR_BASE = 7'h60
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_config_allowed,
    input  wire [15:0] i_telemetry_enable,

    input  wire        i_cfg_ram_wr_en,
    input  wire [9:0]  i_cfg_ram_wr_addr,
    input  wire [31:0] i_cfg_ram_wr_data,
    input  wire        i_cfg_start,
    output wire        o_cfg_ready,
    input  wire [5:0]  i_cfg_device_id,
    input  wire [10:0] i_cfg_record_count,
    input  wire        i_cfg_store_after,
    input  wire        i_cfg_config_mode,
    input  wire        i_cfg_result_rd_en,
    input  wire [9:0]  i_cfg_result_rd_addr,
    output wire [15:0] o_cfg_result_rd_data,
    input  wire        i_tel_rd_en,
    input  wire [8:0]  i_tel_rd_addr,
    output wire [31:0] o_tel_rd_data,

    output wire        o_cfg_resp_valid,
    output wire        o_cfg_resp_error,
    output wire [3:0]  o_cfg_sys_error_code,
    output wire [4:0]  o_cfg_bus_error_code,
    output wire [9:0]  o_cfg_error_index,
    output wire [15:0] o_cfg_last_mtp_crc,
    inout  wire        io_i2c_scl,
    inout  wire        io_i2c_sda
);

    wire cfg_ram_rd_en;
    wire [9:0] cfg_ram_rd_addr;
    wire [31:0] cfg_ram_rd_data;
    wire cfg_result_wr_en;
    wire [9:0] cfg_result_wr_addr;
    wire [15:0] cfg_result_wr_data;
    wire tel_wr_en;
    wire [8:0] tel_wr_addr;
    wire [31:0] tel_wr_data;
    wire scl_o;
    wire scl_t;
    wire sda_o;
    wire sda_t;

    assign io_i2c_scl = scl_t ? 1'bz : scl_o;
    assign io_i2c_sda = sda_t ? 1'bz : sda_o;

    // RAM A 口用于通信写入，B 口完全归本路 service 使用。
    jwh_cfg_cmd_ram u_cfg_cmd_ram (
        .dia   (i_cfg_ram_wr_data),
        .addra (i_cfg_ram_wr_addr),
        .cea   (i_cfg_ram_wr_en),
        .clka  (i_clk),
        .dob   (cfg_ram_rd_data),
        .addrb (cfg_ram_rd_addr),
        .ceb   (cfg_ram_rd_en),
        .clkb  (i_clk)
    );

    // 每条配置记录的结果写入本路结果 RAM，B 口供外部同步读取。
    jwh_cfg_result_ram u_cfg_result_ram (
        .dia   (cfg_result_wr_data),
        .addra (cfg_result_wr_addr),
        .cea   (cfg_result_wr_en),
        .clka  (i_clk),
        .dob   (o_cfg_result_rd_data),
        .addrb (i_cfg_result_rd_addr),
        .ceb   (i_cfg_result_rd_en),
        .clkb  (i_clk)
    );

    // 后台遥测结果写入本路遥测 RAM，B 口供外部同步读取。
    jwh_telemetry_ram u_telemetry_ram (
        .dia   (tel_wr_data),
        .addra (tel_wr_addr),
        .cea   (tel_wr_en),
        .clka  (i_clk),
        .dob   (o_tel_rd_data),
        .addrb (i_tel_rd_addr),
        .ceb   (i_tel_rd_en),
        .clkb  (i_clk)
    );

    jwh6374_bus_service #(
        .P_SYS_CLK_FREQ    (CLK_FREQ_HZ),
        .P_I2C_BAUD_RATE   (I2C_BAUD_RATE),
        .P_I2C_TIMEOUT_MS  (35),
        .P_PEC_ENABLE     (1'b1),
        .P_TCA_ENABLE     (TCA_ENABLE),
        .P_JWH_ADDR_BASE   (JWH_ADDR_BASE),
        .P_MAX_CFG_RECORDS (1024)
    ) u_bus_service (
        .i_clk                  (i_clk),
        .i_rst_n                (i_rst_n),
        .i_clear                (1'b0),
        .i_config_allowed       (i_config_allowed),
        .i_cfg_start            (i_cfg_start),
        .o_cfg_ready            (o_cfg_ready),
        .i_cfg_config_mode      (i_cfg_config_mode),
        .i_cfg_device_id        (i_cfg_device_id),
        .i_cfg_record_count     (i_cfg_record_count),
        .i_cfg_store_after      (i_cfg_store_after),
        .i_cfg_resp_ready       (1'b1),
        .o_cfg_resp_valid          (o_cfg_resp_valid),
        .o_cfg_resp_error          (o_cfg_resp_error),
        .o_cfg_sys_error_code      (o_cfg_sys_error_code),
        .o_cfg_bus_error_code      (o_cfg_bus_error_code),
        .o_cfg_error_index         (o_cfg_error_index),
        .o_cfg_last_mtp_crc        (o_cfg_last_mtp_crc),
        .o_cfg_result_wr_en        (cfg_result_wr_en),
        .o_cfg_result_wr_addr      (cfg_result_wr_addr),
        .o_cfg_result_wr_data      (cfg_result_wr_data),
        .o_cfg_ram_rd_en        (cfg_ram_rd_en),
        .o_cfg_ram_rd_addr      (cfg_ram_rd_addr),
        .i_cfg_ram_rd_data      (cfg_ram_rd_data),
        .i_telemetry_enable     (i_telemetry_enable),
        .o_tel_wr_en            (tel_wr_en),
        .o_tel_wr_addr          (tel_wr_addr),
        .o_tel_wr_data          (tel_wr_data),
        .i_smb_alert_n          (8'hFF),
        .o_alert_report_valid   (),
        .i_alert_report_ready   (1'b1),
        .o_alert_report_channel (),
        .o_alert_report_device_mask (),
        .o_current_device_id    (),
        .i_scl_i                (io_i2c_scl),
        .o_scl_o                (scl_o),
        .o_scl_t                (scl_t),
        .i_sda_i                (io_i2c_sda),
        .o_sda_o                (sda_o),
        .o_sda_t                (sda_t)
    );

endmodule
