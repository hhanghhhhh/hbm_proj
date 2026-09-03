`timescale 1ns / 1ps

/*
 * Module Contract
 *
 * 模块职责：
 * - 封装一条物理 I2C 总线的配置命令 RAM、结果 RAM、遥测 RAM 和业务 service。
 * - 提供通信侧配置写入/结果读取、遥测读取以及开漏式 I2C 引脚连接。
 * - 不负责：识别通信 CMD/BUS、解释结果数据、生成上层响应或取消已接收任务。
 *
 * 输入事务：
 * - i_cfg_ram_wr_en 在当前上升沿向 1024x32 命令 RAM 写入一条配置记录。
 * - 空闲 ready 下的 i_cfg_start 及参数由内部 service 接收，执行单颗器件任务。
 * - i_cfg_result_rd_en 和 i_tel_rd_en 分别发起结果 RAM 与遥测 RAM 的同步读取。
 *
 * 输出事务：
 * - 配置完成信息、错误位置和最后 MTP CRC 原样输出自 service。
 * - 结果 RAM 为 1024x16，遥测 RAM 为 512x32；读数据保持各 RAM 的同步读时序。
 * - i_telemetry_enable 的 16 位分别控制本总线 8 个设备的两个 Rail 后台采集。
 *
 * 关键时序：
 * - service 响应在本模块内固定 ready=1，o_cfg_resp_valid 可能仅保持到下一拍握手。
 * - SMB_ALERT 输入固定为无告警，因此本实例不会输出有效告警调查结果。
 * - io_i2c_scl/io_i2c_sda 以三态输出实现开漏连接，释放时由板级上拉维持高电平。
 *
 * 异常与恢复：
 * - reset：异步低有效，由各 RAM/service 按其接口复位行为处理。
 * - service 的 i_clear 固定为 0；通信 abort 不会通过本模块撤销 I2C 任务。
 *
 * 使用约束：
 * - 外部必须已按 BUS 选通写/启动/读使能，且同一任务执行期间不得覆盖命令 RAM。
 * - 所有接口使用 i_clk；工程必须提供三个真实 RAM IP 及 service/controller 依赖。
 * - TCA 和设备号到物理地址的语义由内部 service 及参数决定。
 *
 * 参考：
 * - DUT_POWER_CONTROL_FLOW.md：单总线配置执行与遥测存储流程。
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

    jwh6374_bus_service_demo_8 #(
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
