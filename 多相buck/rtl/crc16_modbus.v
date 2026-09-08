`timescale 1ns / 1ps

/*
 * 模块说明
 *
 * 功能：
 * - 按 CRC-16/MODBUS 算法逐字节累计并输出当前 CRC；帧边界、参与字段和
 *   最终传输字节序由调用模块决定。
 *
 * 关键数据：
 * - 初值为 16'hFFFF，使用反射多项式 16'hA001，输入字节最低位优先计算。
 *
 * 特殊行为：
 * - i_init 与 i_data_valid 同拍时，从初值开始累计当前字节，便于帧首字节
 *   同时启动新一轮 CRC；只有 i_init 时则仅恢复初值。
 * - i_rst_n 在 i_clk 上升沿同步采样，与工程中常用的异步复位不同。
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
        /* 同步低有效复位；初始化与数据同拍时从初值累计当前字节。 */
        if (!i_rst_n) begin
            o_crc <= 16'hFFFF;
        end else if (i_init) begin
            if (i_data_valid) begin
                o_crc <= next_crc16_modbus(16'hFFFF, i_data);
            end else begin
                o_crc <= 16'hFFFF;
            end
        end else if (i_data_valid) begin
            o_crc <= next_crc16_modbus(o_crc, i_data);
        end
    end

endmodule
