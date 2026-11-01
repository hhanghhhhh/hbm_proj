`timescale 1ns/1ps
`include "udp_cmd_defs.vh"
/* SYSTEM_STATUS 请求时锁存完整状态，防止五字节响应跨时刻拼接。
 * CFG/SEQ 结果由 System Controller 按真实执行事件保持，不由查询请求推断。
 */
module udp_status_application (
    input wire i_clk, input wire i_rst_n, input wire i_abort,
    input wire i_req_valid, input wire [15:0] i_req_length,
    input wire [7:0] i_sys_state, input wire [1:0] i_cfg_result,
    input wire [1:0] i_seq_result, input wire [7:0] i_fault_vector,
    output reg o_rsp_wr_en, output reg [10:0] o_rsp_wr_addr,
    output reg [7:0] o_rsp_wr_data, output wire [15:0] o_rsp_length,
    output reg o_rsp_valid, output reg o_error_valid, output wire [7:0] o_error_code
);
localparam [1:0] ST_IDLE=0, ST_WRITE=1, ST_DONE=2;
reg [1:0] state;
reg [39:0] snapshot;
reg [2:0] byte_index;
assign o_rsp_length=16'd5;
assign o_error_code=`UDP_LENGTH_ERROR;
always @(posedge i_clk or negedge i_rst_n) begin
    if(!i_rst_n) begin
        state<=ST_IDLE; snapshot<=0; byte_index<=0;
        o_rsp_wr_en<=0; o_rsp_wr_addr<=0; o_rsp_wr_data<=0;
        o_rsp_valid<=0; o_error_valid<=0;
    end else begin
        o_rsp_wr_en<=0; o_rsp_valid<=0; o_error_valid<=0;
        if(i_abort) state<=ST_IDLE;
        else case(state)
            ST_IDLE: if(i_req_valid) begin
                if(i_req_length!=0) o_error_valid<=1;
                else begin
                    snapshot<={8'd0,i_sys_state,6'd0,i_cfg_result,6'd0,i_seq_result,i_fault_vector};
                    byte_index<=0; state<=ST_WRITE;
                end
            end
            ST_WRITE: begin
                o_rsp_wr_en<=1; o_rsp_wr_addr<={8'd0,byte_index}; o_rsp_wr_data<=snapshot[39:32];
                snapshot<={snapshot[31:0],8'd0};
                if(byte_index==4) state<=ST_DONE;
                else byte_index<=byte_index+1'b1;
            end
            ST_DONE: begin o_rsp_valid<=1; state<=ST_IDLE; end
            default: state<=ST_IDLE;
        endcase
    end
end
endmodule
