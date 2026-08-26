`timescale 1ns / 1ps

/*
 * 流式 CRC-16/MODBUS 计算模块。
 *
 * i_init 有效时同步装载标准初值 16'hFFFF。i_data_valid 每有效一个周期
 * 接收一个字节，按最低位优先方式使用反射多项式 16'hA001 进行计算。
 * o_crc 直接输出 16 位 CRC 数值，帧上传输时的高低字节顺序由上层模块
 * 决定。i_init 的优先级高于 i_data_valid。
 */
module crc16_modbus (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_init,
    input  wire        i_data_valid,
    input  wire [7:0]  i_data,
    output reg  [15:0] o_crc
);

    /* 组合计算单个输入字节对应的下一拍 CRC 值。 */
    function [15:0] next_crc16_modbus;
        input [15:0] current_crc;
        input [7:0]  data_byte;
        integer      bit_index;
        reg [15:0]   crc_work;
        begin
            /* MODBUS CRC 为反射算法，输入字节与 CRC 低 8 位异或。 */
            crc_work = current_crc ^ {8'h00, data_byte};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (crc_work[0]) begin
                    crc_work = (crc_work >> 1) ^ 16'hA001;
                end else begin
                    crc_work = crc_work >> 1;
                end
            end
            next_crc16_modbus = crc_work;
        end
    endfunction

    always @(posedge i_clk) begin
        /* 同步低有效复位；初始化请求优先于数据累计。 */
        if (!i_rst_n) begin
            o_crc <= 16'hFFFF;
        end else if (i_init) begin
            o_crc <= 16'hFFFF;
        end else if (i_data_valid) begin
            o_crc <= next_crc16_modbus(o_crc, i_data);
        end
    end

endmodule
