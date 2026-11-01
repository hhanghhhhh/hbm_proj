`timescale 1ns/1ps
/* 沿用旧 error_response_generator 的一字节错误写入/提交结构。 */
module udp_error_response (
    input wire i_clk, input wire i_rst_n, input wire i_abort,
    input wire i_error_valid, input wire [7:0] i_error_code,
    output reg o_rsp_wr_en, output wire [10:0] o_rsp_wr_addr,
    output reg [7:0] o_rsp_wr_data, output wire [15:0] o_rsp_length,
    output reg o_rsp_valid
);
assign o_rsp_wr_addr=11'd0;
assign o_rsp_length=16'd1;
always @(posedge i_clk or negedge i_rst_n) begin
    if(!i_rst_n) begin o_rsp_wr_en<=0; o_rsp_wr_data<=0; o_rsp_valid<=0; end
    else begin
        o_rsp_wr_en<=0; o_rsp_valid<=0;
        if(!i_abort) begin
            if(i_error_valid) begin o_rsp_wr_en<=1; o_rsp_wr_data<=i_error_code; end
            if(o_rsp_wr_en) o_rsp_valid<=1;
        end
    end
end
endmodule
