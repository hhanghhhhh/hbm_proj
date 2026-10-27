`timescale 1ns/1ps

/*
 * 简版测量缓存：接收 AD4114 有效采样，覆盖保存各通道的最新 24-bit 原码。
 * 通道地址 = ADC_ID * 8 + ADC_CHANNEL；16 颗 ADC 对应 128 路，不区分 V/I。
 * 通信侧按 TELEMETRY_READ 的 Mask 升序提交地址，将返回值按高字节在前组包：
 * [47:24] 为 Voltage Raw（当前采样），[23:0] 为 Current Raw（固定 0）。
 * 所有接口共用 i_clk。读请求在上升沿接受，沿后 rd_valid/data 有效；可逐拍读。
 * 未采样地址返回 0。RAM 不清零，只复位已写标志；同地址读写碰撞的数据不作保证。
 * RAM IP：measurement_result_ram，简单双口 128 x 24，A 写/B 读，7-bit 地址，
 * B 口同步读、不开额外输出寄存器；端口形式与 config_manager 的 cfg_ram 一致。
 */
module measurement_manager (
    input  wire         i_clk,
    input  wire         i_rst_n,

    input  wire         i_sample_valid,
    input  wire [7:0]   i_sample_adc_id,
    input  wire [2:0]   i_sample_channel,
    input  wire [23:0]  i_sample_data,

    input  wire         i_result_rd_en,
    input  wire [6:0]   i_result_rd_addr,
    output reg          o_result_rd_valid,
    output wire [47:0]  o_result_rd_data
);

wire [6:0]  result_wr_addr;
wire        result_wr_en;
wire [23:0] result_rd_data;
reg [127:0] channel_written;
reg         result_rd_written;

assign result_wr_addr = {i_sample_adc_id[3:0], i_sample_channel};
assign result_wr_en   = i_rst_n && i_sample_valid && (i_sample_adc_id < 8'd16);
assign o_result_rd_data = {result_rd_written ? result_rd_data : 24'd0, 24'd0};

measurement_result_ram u_measurement_result_ram (
    .dia   (i_sample_data),
    .addra (result_wr_addr),
    .cea   (result_wr_en),
    .clka  (i_clk),
    .dob   (result_rd_data),
    .addrb (i_result_rd_addr),
    .ceb   (i_result_rd_en && i_rst_n),
    .clkb  (i_clk)
);

// 已写标志与 RAM 读口同拍取样，避免上电 RAM 初值或复位前旧数据被读出。
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        channel_written   <= 128'd0;
        result_rd_written <= 1'b0;
        o_result_rd_valid <= 1'b0;
    end
    else begin
        o_result_rd_valid <= 1'b0;

        if (result_wr_en)
            channel_written[result_wr_addr] <= 1'b1;

        if (i_result_rd_en) begin
            result_rd_written <= channel_written[i_result_rd_addr];
            o_result_rd_valid <= 1'b1;
        end
    end
end

endmodule
