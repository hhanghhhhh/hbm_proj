`timescale 1ns/1ps
`include "udp_cmd_defs.vh"
/* 原子保存128-bit大端使能位图，按通道号递增回读48-bit结果。
 * 单通道一次锁存完整六字节，再写响应 RAM；不同通道不是同一时刻快照。
 * 只读缓存，不触发 ADC 转换。当前缓存的低24位电流字段固定为0。
 */
module udp_telemetry_application (
    input wire i_clk, input wire i_rst_n, input wire i_abort,
    input wire i_req_valid, input wire [7:0] i_req_cmd,
    input wire [15:0] i_req_length,
    output reg [10:0] o_payload_rd_addr, input wire [7:0] i_payload_rd_data,
    output reg o_rsp_wr_en, output reg [10:0] o_rsp_wr_addr,
    output reg [7:0] o_rsp_wr_data, output reg [15:0] o_rsp_length,
    output reg o_rsp_valid, output reg o_error_valid, output wire [7:0] o_error_code,
    output reg [127:0] o_enable_mask,
    output reg o_result_rd_en, output reg [6:0] o_result_rd_addr,
    input wire i_result_rd_valid, input wire [47:0] i_result_rd_data
);
localparam [3:0] ST_IDLE=0, ST_READ_WAIT=1, ST_READ_BYTE=2,
    ST_STATUS=3, ST_FIND=4, ST_RAM_WAIT=5, ST_RAM_CAPTURE=6,
    ST_CHANNEL_WRITE=7, ST_DONE=8;
reg [3:0] state;
reg [127:0] request_mask;
reg [7:0] channel_index, selected_count;
reg [2:0] byte_index;
reg [47:0] result_shift;
reg [10:0] rsp_addr;
reg is_enable;
wire [127:0] mask_next = {request_mask[119:0], i_payload_rd_data};
assign o_error_code = `UDP_LENGTH_ERROR;
function [3:0] f_count_byte;
    input [7:0] data;
    integer bit_index;
    begin
        f_count_byte=0;
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)
            f_count_byte=f_count_byte+data[bit_index];
    end
endfunction
always @(posedge i_clk or negedge i_rst_n) begin
    if(!i_rst_n) begin
        state<=ST_IDLE; o_payload_rd_addr<=0; request_mask<=0;
        channel_index<=0; selected_count<=0; byte_index<=0; result_shift<=0;
        rsp_addr<=0; is_enable<=0; o_enable_mask<=0;
        o_result_rd_en<=0; o_result_rd_addr<=0;
        o_rsp_wr_en<=0; o_rsp_wr_addr<=0; o_rsp_wr_data<=0;
        o_rsp_length<=0; o_rsp_valid<=0; o_error_valid<=0;
    end else begin
        o_rsp_wr_en<=0; o_rsp_valid<=0; o_error_valid<=0; o_result_rd_en<=0;
        if(i_abort) state<=ST_IDLE;
        else case(state)
            ST_IDLE: if(i_req_valid) begin
                if(i_req_length!=16) o_error_valid<=1;
                else begin
                    is_enable<=(i_req_cmd==`UDP_CMD_TEL_ENABLE);
                    request_mask<=0; selected_count<=0; o_payload_rd_addr<=0;
                    channel_index<=0; rsp_addr<=1; state<=ST_READ_WAIT;
                end
            end
            ST_READ_WAIT: state<=ST_READ_BYTE;
            ST_READ_BYTE: begin
                request_mask<=mask_next;
                selected_count<=selected_count+f_count_byte(i_payload_rd_data);
                if(o_payload_rd_addr==15) begin
                    if(is_enable) begin o_enable_mask<=mask_next; o_rsp_length<=1; end
                    else o_rsp_length<=16'd1+(selected_count+f_count_byte(i_payload_rd_data))*16'd6;
                    state<=ST_STATUS;
                end else begin o_payload_rd_addr<=o_payload_rd_addr+1'b1; state<=ST_READ_WAIT; end
            end
            ST_STATUS: begin
                o_rsp_wr_en<=1; o_rsp_wr_addr<=0; o_rsp_wr_data<=`UDP_SUCCESS;
                state<=is_enable ? ST_DONE : ST_FIND;
            end
            ST_FIND: begin
                if(channel_index==128) state<=ST_DONE;
                else if(request_mask[channel_index[6:0]]) begin
                    o_result_rd_en<=1; o_result_rd_addr<=channel_index[6:0];
                    state<=ST_RAM_WAIT;
                end else channel_index<=channel_index+1'b1;
            end
            ST_RAM_WAIT: state<=ST_RAM_CAPTURE;
            ST_RAM_CAPTURE: if(i_result_rd_valid) begin
                result_shift<=i_result_rd_data; byte_index<=0; state<=ST_CHANNEL_WRITE;
            end
            ST_CHANNEL_WRITE: begin
                o_rsp_wr_en<=1; o_rsp_wr_addr<=rsp_addr;
                o_rsp_wr_data<=result_shift[47:40];
                result_shift<={result_shift[39:0],8'd0}; rsp_addr<=rsp_addr+1'b1;
                if(byte_index==5) begin channel_index<=channel_index+1'b1; state<=ST_FIND; end
                else byte_index<=byte_index+1'b1;
            end
            ST_DONE: begin o_rsp_valid<=1; state<=ST_IDLE; end
            default: state<=ST_IDLE;
        endcase
    end
end
endmodule
