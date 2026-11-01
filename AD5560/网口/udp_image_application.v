`timescale 1ns/1ps
`include "udp_cmd_defs.vh"
/* Config/PSE 共用的精简 Image 下载流程，分别例化独立 FSM。
 * IS_POWER=0：32-bit Record/1024项，START为长度+CRC；
 * IS_POWER=1：16-bit Word/2048项，START为MODE+长度+CRC。
 * Payload 一拍同步读，WAIT/READ 两拍取一个字节；不解释 Record 内容。
 * Image CRC 与外层帧 CRC 独立。CRC失败回 SUCCESS+CRC_OK=0，不发启动。
 */
module udp_image_application #(parameter IS_POWER=0) (
    input wire i_clk, input wire i_rst_n, input wire i_abort,
    input wire i_req_valid, input wire [7:0] i_req_cmd,
    input wire [15:0] i_req_length,
    output reg [10:0] o_payload_rd_addr, input wire [7:0] i_payload_rd_data,
    output reg o_rsp_wr_en, output reg [10:0] o_rsp_wr_addr,
    output reg [7:0] o_rsp_wr_data, output reg [15:0] o_rsp_length,
    output reg o_rsp_valid, output reg o_error_valid, output reg [7:0] o_error_code,
    input wire i_write_allowed, input wire i_start_allowed,
    output wire o_ram_wr_en, output reg [10:0] o_ram_wr_addr,
    output reg [31:0] o_ram_wr_data,
    output reg [11:0] o_word_count, output reg [15:0] o_expected_crc,
    output reg o_crc_start, input wire i_crc_done, input wire i_crc_ok,
    output wire o_start_req, output reg o_mode
);
localparam WORD_BYTES = IS_POWER ? 2 : 4;
localparam CAPACITY = IS_POWER ? 2048 : 1024;
localparam START_LENGTH = IS_POWER ? 5 : 4;
localparam [3:0] ST_IDLE=0, ST_READ_WAIT=1, ST_READ_BYTE=2,
    ST_WRITE=3, ST_CRC_WAIT=4, ST_START=5,
    ST_STATUS=6, ST_CRC_RESULT=7, ST_RSP_DONE=8;
reg [3:0] state;
reg [15:0] req_length;
reg is_start;
reg [15:0] offset;
reg [31:0] word_shift;
reg [1:0] byte_index;
reg [39:0] start_shift;
reg crc_result;
wire [39:0] start_next = {start_shift[31:0], i_payload_rd_data};
wire [15:0] word_total = (req_length - 16'd2) / WORD_BYTES;
wire [16:0] end_addr = {1'b0, offset[7:0], i_payload_rd_data} + {1'b0, word_total};
assign o_ram_wr_en = (state == ST_WRITE) && i_write_allowed && !i_abort;
// 与 System 的 allowed 同沿握手，进入本状态后只提交一次。
assign o_start_req = (state == ST_START) && i_start_allowed && !i_abort;
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state <= ST_IDLE; req_length <= 0; is_start <= 0;
        offset <= 0; word_shift <= 0; byte_index <= 0; start_shift <= 0;
        crc_result <= 0; o_payload_rd_addr <= 0;
        o_rsp_wr_en <= 0; o_rsp_wr_addr <= 0; o_rsp_wr_data <= 0;
        o_rsp_length <= 0; o_rsp_valid <= 0; o_error_valid <= 0; o_error_code <= 0;
        o_ram_wr_addr <= 0; o_ram_wr_data <= 0;
        o_word_count <= 0; o_expected_crc <= 0; o_crc_start <= 0; o_mode <= 0;
    end else begin
        o_rsp_wr_en <= 0; o_rsp_valid <= 0; o_error_valid <= 0; o_crc_start <= 0;
        if (i_abort) state <= ST_IDLE;
        else case (state)
            ST_IDLE: if (i_req_valid) begin
                req_length <= i_req_length;
                is_start <= (i_req_cmd == (IS_POWER ? `UDP_CMD_POWER_START : `UDP_CMD_CONFIG_START));
                o_payload_rd_addr <= 0; start_shift <= 0;
                byte_index <= 0; word_shift <= 0;
                if (((i_req_cmd == (IS_POWER ? `UDP_CMD_POWER_START : `UDP_CMD_CONFIG_START)) &&
                     i_req_length != START_LENGTH) ||
                    ((i_req_cmd == (IS_POWER ? `UDP_CMD_POWER_DATA : `UDP_CMD_CONFIG_DATA)) &&
                     ((i_req_length < WORD_BYTES+2) || ((i_req_length-2)%WORD_BYTES != 0)))) begin
                    o_error_valid <= 1; o_error_code <= `UDP_LENGTH_ERROR;
                end else if (!i_write_allowed ||
                    ((i_req_cmd == (IS_POWER ? `UDP_CMD_POWER_START : `UDP_CMD_CONFIG_START)) && !i_start_allowed)) begin
                    o_error_valid <= 1; o_error_code <= `UDP_PARAM_ERROR;
                end else state <= ST_READ_WAIT;
            end
            ST_READ_WAIT: state <= ST_READ_BYTE;
            ST_READ_BYTE: begin
                if (is_start) begin
                    start_shift <= start_next;
                    if (o_payload_rd_addr == req_length-1) begin
                        if ((start_next[31:16] > CAPACITY) ||
                            (IS_POWER && ((start_next[39:32] > 1) || (start_next[31:16] < 20)))) begin
                            o_error_valid <= 1; o_error_code <= `UDP_PARAM_ERROR; state <= ST_IDLE;
                        end else if (!i_write_allowed || !i_start_allowed) begin
                            o_error_valid <= 1; o_error_code <= `UDP_PARAM_ERROR; state <= ST_IDLE;
                        end else begin
                            o_word_count <= start_next[27:16];
                            o_expected_crc <= start_next[15:0];
                            o_mode <= IS_POWER ? start_next[32] : 1'b0;
                            o_crc_start <= 1; state <= ST_CRC_WAIT;
                        end
                    end else begin o_payload_rd_addr <= o_payload_rd_addr+1'b1; state <= ST_READ_WAIT; end
                end else if (o_payload_rd_addr == 0) begin
                    offset <= {8'd0, i_payload_rd_data};
                    o_payload_rd_addr <= 1; state <= ST_READ_WAIT;
                end else if (o_payload_rd_addr == 1) begin
                    if (end_addr > CAPACITY) begin
                        o_error_valid <= 1; o_error_code <= `UDP_PARAM_ERROR; state <= ST_IDLE;
                    end else begin
                        o_ram_wr_addr <= {offset[2:0], i_payload_rd_data};
                        o_payload_rd_addr <= 2; state <= ST_READ_WAIT;
                    end
                end else begin
                    word_shift <= {word_shift[23:0], i_payload_rd_data};
                    if (byte_index == WORD_BYTES-1) begin
                        o_ram_wr_data <= {word_shift[23:0], i_payload_rd_data};
                        byte_index <= 0; state <= ST_WRITE;
                    end else begin
                        byte_index <= byte_index+1'b1;
                        o_payload_rd_addr <= o_payload_rd_addr+1'b1; state <= ST_READ_WAIT;
                    end
                end
            end
            ST_WRITE: begin
                if (!i_write_allowed) begin
                    o_error_valid <= 1; o_error_code <= `UDP_PARAM_ERROR; state <= ST_IDLE;
                end else if (o_payload_rd_addr == req_length-1) begin
                    o_rsp_length <= 1; state <= ST_STATUS;
                end else begin
                    o_ram_wr_addr <= o_ram_wr_addr+1'b1;
                    o_payload_rd_addr <= o_payload_rd_addr+1'b1; state <= ST_READ_WAIT;
                end
            end
            ST_CRC_WAIT: if (i_crc_done) begin
                crc_result <= i_crc_ok; o_rsp_length <= 2;
                state <= i_crc_ok ? ST_START : ST_STATUS;
            end
            ST_START: begin
                if (i_start_allowed) state <= ST_STATUS;
                else begin o_error_valid <= 1; o_error_code <= `UDP_PARAM_ERROR; state <= ST_IDLE; end
            end
            ST_STATUS: begin
                o_rsp_wr_en <= 1; o_rsp_wr_addr <= 0; o_rsp_wr_data <= `UDP_SUCCESS;
                state <= is_start ? ST_CRC_RESULT : ST_RSP_DONE;
            end
            ST_CRC_RESULT: begin
                o_rsp_wr_en <= 1; o_rsp_wr_addr <= 1; o_rsp_wr_data <= {7'd0, crc_result};
                state <= ST_RSP_DONE;
            end
            ST_RSP_DONE: begin o_rsp_valid <= 1; state <= ST_IDLE; end
            default: state <= ST_IDLE;
        endcase
    end
end
endmodule
