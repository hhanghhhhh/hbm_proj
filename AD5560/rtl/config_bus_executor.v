`timescale 1ns/1ps

/*
 * 保存一个 BUS 的阶段 WRITE，阶段分发完后才允许执行。
 * 每路固定 1024 x 27 bit，计数为 11 bit，以区分空与满 1024 条。
 * RAM 同步读且不复位；clear 仅丢弃指针和有效位，不撤销已交给 Driver 的事务。
 */
module config_bus_executor (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_clear, // 清除本 BUS 的队列状态
    input  wire        i_load, // 向本 BUS 队列写入一条 Record
    input  wire [26:0] i_record, // 要写入的 Device、寄存器、数据
    input  wire        i_start, // 本阶段分发完成，开始读取执行
    input  wire        i_take, // 当前队首命令已成功提交
    output wire        o_pending, // 是否还有未提交的命令
    output wire        o_valid, // 当前队首命令是否已经准备好
    output wire [26:0] o_record // 当前队首命令
);

localparam [1:0] ST_COLLECT = 2'd0;
localparam [1:0] ST_READ    = 2'd1;
localparam [1:0] ST_LOAD    = 2'd2;
localparam [1:0] ST_HEAD    = 2'd3;

reg [1:0] state;
reg [26:0] queue_ram [0:1023];
reg [26:0] ram_rd_data;
reg [26:0] head_record;
reg [10:0] write_count;
reg [10:0] read_count;

assign o_pending = (write_count != read_count);
assign o_valid = (state == ST_HEAD) && !i_clear;
assign o_record = head_record;

// 分发与执行不重叠；存储阵列不加复位，便于推断为块 RAM。
always @(posedge i_clk) begin
    if (i_load && !i_clear && (state == ST_COLLECT) && (write_count < 11'd1024))
        queue_ram[write_count[9:0]] <= i_record;
    if (state == ST_READ)
        ram_rd_data <= queue_ram[read_count[9:0]];
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state <= ST_COLLECT;
        write_count <= 11'd0;
        read_count <= 11'd0;
        head_record <= 27'd0;
    end
    else if (i_clear) begin
        state <= ST_COLLECT;
        write_count <= 11'd0;
        read_count <= 11'd0;
        head_record <= 27'd0;
    end
    else begin
        case (state)
            ST_COLLECT: begin
                if (i_load && (write_count < 11'd1024))
                    write_count <= write_count + 11'd1;
                if (i_start && (write_count != 11'd0))
                    state <= ST_READ;
            end
            ST_READ: state <= ST_LOAD;
            ST_LOAD: begin
                head_record <= ram_rd_data;
                state <= ST_HEAD;
            end
            ST_HEAD: begin
                // take 只在公共出口真正握手时有效，不因仲裁选中而提前弹出。
                if (i_take) begin
                    read_count <= read_count + 11'd1;
                    if (read_count + 11'd1 == write_count)
                        state <= ST_COLLECT;
                    else
                        state <= ST_READ;
                end
            end
            default: begin
                state <= ST_COLLECT;
                write_count <= 11'd0;
                read_count <= 11'd0;
            end
        endcase
    end
end

endmodule
