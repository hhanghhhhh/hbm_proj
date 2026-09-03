`timescale 1ns / 1ps

/*
 * Module Contract
 *
 * 模块职责：
 * - 按 CRC-16/MODBUS 算法逐字节累计并输出当前 16 位 CRC 数值。
 * - 不负责：划分帧边界、选择参与计算的字段或规定 CRC 的传输字节序。
 *
 * 输入事务：
 * - i_init=1 在当前上升沿开始一次新的累计，初值为 16'hFFFF。
 * - i_data_valid=1 时在当前上升沿接收 i_data，并基于此前 o_crc 累计一个字节。
 * - i_init 与 i_data_valid 同拍有效时，以 16'hFFFF 为初值累计该字节，使调用者可在
 *   帧首字节到达时同时启动新一轮 CRC。
 *
 * 输出事务：
 * - 每接收一个有效字节，o_crc 在该上升沿后更新为包含该字节的 CRC。
 * - 无初始化和数据有效事件时，o_crc 保持不变；模块不产生 done/valid 脉冲。
 *
 * 关键时序：
 * - 算法使用初值 16'hFFFF、反射多项式 16'hA001，并按输入字节最低位优先计算。
 * - 上游若要读取最终 CRC，应在最后一个 i_data_valid 上升沿之后使用 o_crc。
 *
 * 异常与恢复：
 * - reset：i_rst_n 在 i_clk 上升沿同步采样；低电平时将 o_crc 置为 16'hFFFF。
 * - 模块没有 abort、错误检测或超时接口；重新开始累计必须由上游发出 i_init。
 *
 * 使用约束：
 * - i_data 必须在 i_data_valid 对应的采样沿满足同步时序要求。
 * - 帧内字段范围及最终高低字节发送顺序由调用模块保证。
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
