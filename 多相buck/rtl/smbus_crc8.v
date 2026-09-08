`timescale 1ns / 1ps

/*
**定位**：SMBus Packet Error Code (PEC) 的 CRC-8 字节更新器。

#### 1. CRC 参数
*   多项式：x^8 + x^2 + x + 1 (`8'h07`)
*   初始值：`8'h00`
*   输入顺序：每个字节 MSB first
*   RefIn/RefOut：False
*   XorOut：`8'h00`

#### 2. 接口约定
*   `i_clear`：开始一笔新的 SMBus 事务前拉高一拍，CRC 清零。
*   `i_data_valid`：待计算字节有效时拉高一拍。
*   `o_crc`：已经纳入所有有效字节后的当前 CRC。
*   `i_clear` 优先级高于 `i_data_valid`，两者不应在同一拍置高。

#### 3. 时序结构
*   一个字节的 8 次 bit 运算由组合逻辑完成，结果在时钟沿写入寄存器。
*   调用者在提交最后一个数据字节后，应至少等待一拍再读取 `o_crc` 发送 PEC。
*/

module smbus_crc8 (
    input  wire       i_clk,
    input  wire       i_rst_n,
    input  wire       i_clear,
    input  wire       i_data_valid,
    input  wire [7:0] i_data,
    output reg  [7:0] o_crc
);

    // =========================================================================
    // CRC-8/SMBus 单字节组合更新函数
    // =========================================================================
    function [7:0] f_crc8_next;
        input [7:0] i_crc;
        input [7:0] i_byte;

        reg [7:0] crc_work;
        integer   bit_index;
        begin
            crc_work = i_crc;

            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                if (crc_work[7] ^ i_byte[bit_index]) begin
                    crc_work = {crc_work[6:0], 1'b0} ^ 8'h07;
                end else begin
                    crc_work = {crc_work[6:0], 1'b0};
                end
            end

            f_crc8_next = crc_work;
        end
    endfunction

    // =========================================================================
    // CRC 结果寄存器
    // =========================================================================
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_crc <= 8'h00;
        end else if (i_clear) begin
            o_crc <= 8'h00;
        end else if (i_data_valid) begin
            o_crc <= f_crc8_next(o_crc, i_data);
        end
    end

endmodule

