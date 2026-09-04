`timescale 1ns / 1ps

/*
 * 模块说明
 *
 * 功能：
 * - 从内部 16 位 RAM 读取并执行 128 路 EN 绝对状态序列；每一步完整
 *   缓存后原子更新全部 EN，再按毫秒延时进入下一步。
 *
 * 关键数据：
 * - RAM 地址、序列号和步骤号均为 0-based。前 P_SEQUENCE_COUNT 个 word
 *   为目录：Reserved[15]、StepCount[14:9]、Reserved[8:6]、StartStep[5:0]。
 * - 每一步固定占 9 个 word：word 0..7 依次对应 EN_State[127:112] 至
 *   EN_State[15:0]，word 8 为 Delay_ms，1 LSB=1 ms。
 * - 步骤首地址为 P_SEQUENCE_COUNT + StartStepNumber*9；默认 2 个序列、
 *   每序列最多 32 步，共使用 578 个 16 位 word。
 * - 控制器内部使用移位加法换算：
 *   address = P_SEQUENCE_COUNT + (StartStepNumber << 3) + StartStepNumber
 * - 第一个序列的 StartStepNumber 就是 0，实际程序执行从 P_SEQUENCE_COUNT ram 地址开始取值
 * 关键约束：
 * - 非空目录的 Reserved 必须为 0，StepCount 不得超过 P_MAX_STEPS，且
 *   StartStepNumber、末步骤和 RAM 结束地址均不得越界；空目录必须全 0。
 * - 执行期间不得改写当前序列使用的 RAM 区域。
 *
 * 特殊行为：
 * - 空目录正常完成且不改变 EN；非法序列号或目录产生 error 和 done。
 * - i_emergency_off 或 i_clear 会立即中止序列并清零全部 EN，不产生完成事件。
 */

module en_sequence_controller #(
    parameter integer P_SYS_CLK_FREQ   = 100_000_000,
    parameter integer P_SEQUENCE_COUNT = 2,
    parameter integer P_MAX_STEPS      = 32,
    parameter integer P_RAM_ADDR_WIDTH = 10
)(
    input  wire                          i_clk,
    input  wire                          i_rst_n,
    input  wire                          i_clear,
    input  wire                          i_emergency_off,

    input  wire                          i_start,
    output reg                           o_ready,
    input  wire [3:0]                    i_sequence_id,
    input  wire                          i_ram_wr_en,
    input  wire [P_RAM_ADDR_WIDTH-1:0]   i_ram_wr_addr,
    input  wire [15:0]                   i_ram_wr_data,
    output reg                           o_done,
    output reg                           o_error,
    output reg  [127:0]                  o_en_state,
    output reg  [3:0]                    o_debug_state
);

    localparam [3:0] ST_IDLE         = 4'd0,
                     ST_DESC_REQUEST = 4'd1,
                     ST_DESC_WAIT    = 4'd2,
                     ST_DESC_LATCH   = 4'd3,
                     ST_DESC_CHECK   = 4'd4,
                     ST_STEP_REQUEST = 4'd5,
                     ST_STEP_STREAM  = 4'd6,
                     ST_APPLY        = 4'd7,
                     ST_DELAY        = 4'd8,
                     ST_ADVANCE      = 4'd9;

    localparam integer CYCLES_PER_MS   = P_SYS_CLK_FREQ / 1_000;
    localparam integer DIRECTORY_WORDS = P_SEQUENCE_COUNT;
    localparam integer TOTAL_STEPS     = P_SEQUENCE_COUNT * P_MAX_STEPS;
    localparam integer MAX_SEQUENCE_ID = P_SEQUENCE_COUNT - 1;
    localparam integer MAX_STEP_NUMBER = TOTAL_STEPS - 1;
    localparam [10:0] RAM_WORD_COUNT   = 11'd1 << P_RAM_ADDR_WIDTH;

    reg [3:0]   r_state;
    reg [3:0]   r_desc_reserved;
    reg [5:0]   r_desc_step_count;
    reg [5:0]   r_desc_start_step_number;
    reg [6:0]   r_desc_last_step_number;
    reg [9:0]   r_desc_start_addr;
    reg [10:0]  r_desc_end_addr;
    reg [5:0]   r_step_count;
    reg [5:0]   r_step_index;
    reg [9:0]   r_step_base_addr;
    reg [127:0] r_next_en_state;
    reg [15:0]  r_delay_units;
    reg [15:0]  r_delay_remaining;
    reg [31:0]  r_delay_tick_counter;
    reg [3:0]   r_issue_count;
    reg [3:0]   r_capture_count;
    reg         r_response_valid;
    reg         r_ram_rd_en;
    reg [P_RAM_ADDR_WIDTH-1:0] r_ram_rd_addr;
    wire [15:0] w_ram_rd_data;

    // 时序参数 RAM 放在控制器内部：A 口由应用模块写入，B 口供状态机读取。
    en_seq_ram u_en_seq_ram (
        .dia   (i_ram_wr_data),
        .addra (i_ram_wr_addr),
        .cea   (i_ram_wr_en),
        .clka  (i_clk),
        .dob   (w_ram_rd_data),
        .addrb (r_ram_rd_addr),
        .ceb   (r_ram_rd_en),
        .clkb  (i_clk)
    );

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state                  <= ST_IDLE;
            r_desc_reserved          <= 4'd0;
            r_desc_step_count        <= 6'd0;
            r_desc_start_step_number <= 6'd0;
            r_desc_last_step_number  <= 7'd0;
            r_desc_start_addr        <= 10'd0;
            r_desc_end_addr          <= 11'd0;
            r_step_count             <= 6'd0;
            r_step_index             <= 6'd0;
            r_step_base_addr         <= 10'd0;
            r_next_en_state          <= 128'd0;
            r_delay_units            <= 16'd0;
            r_delay_remaining        <= 16'd0;
            r_delay_tick_counter     <= 32'd0;
            r_issue_count            <= 4'd0;
            r_capture_count          <= 4'd0;
            r_response_valid         <= 1'b0;
            o_ready                  <= 1'b0;
            o_done                   <= 1'b0;
            o_error                  <= 1'b0;
            o_en_state               <= 128'd0;
            r_ram_rd_en              <= 1'b0;
            r_ram_rd_addr            <= {P_RAM_ADDR_WIDTH{1'b0}};
            o_debug_state            <= ST_IDLE;
        end else if (i_clear || i_emergency_off) begin
            r_state              <= ST_IDLE;
            r_response_valid     <= 1'b0;
            r_issue_count        <= 4'd0;
            r_capture_count      <= 4'd0;
            r_delay_remaining    <= 16'd0;
            r_delay_tick_counter <= 32'd0;
            o_ready              <= 1'b0;
            o_done               <= 1'b0;
            o_error              <= 1'b0;
            o_en_state           <= 128'd0;
            r_ram_rd_en          <= 1'b0;
            o_debug_state        <= ST_IDLE;
        end else begin
            r_ram_rd_en      <= 1'b0;
            o_done           <= 1'b0;
            o_debug_state    <= r_state;
            r_response_valid <= r_ram_rd_en;

            case (r_state)
                ST_IDLE: begin
                    o_ready <= 1'b1;
                    if (i_start && o_ready) begin
                        o_ready       <= 1'b0;
                        o_error       <= 1'b0;
                        if (i_sequence_id > MAX_SEQUENCE_ID) begin
                            o_error <= 1'b1;
                            o_done  <= 1'b1;
                            r_state <= ST_IDLE;
                        end else begin
                            r_ram_rd_addr <=
                                {{(P_RAM_ADDR_WIDTH-4){1'b0}}, i_sequence_id};
                            r_state <= ST_DESC_REQUEST;
                        end
                    end
                end

                ST_DESC_REQUEST: begin
                    r_ram_rd_en <= 1'b1;
                    r_state     <= ST_DESC_WAIT;
                end

                ST_DESC_WAIT: begin
                    r_state <= ST_DESC_LATCH;
                end

                ST_DESC_LATCH: begin
                    r_desc_reserved          <= {w_ram_rd_data[15],
                                                 w_ram_rd_data[8:6]};
                    r_desc_step_count        <= w_ram_rd_data[14:9];
                    r_desc_start_step_number <= w_ram_rd_data[5:0];

                    // StartStepNumber 为 0-based；乘 9 只用左移和相加。
                    r_desc_start_addr <= DIRECTORY_WORDS +
                        ({4'd0, w_ram_rd_data[5:0]} << 3) +
                        {4'd0, w_ram_rd_data[5:0]};
                    r_desc_last_step_number <=
                        {1'b0, w_ram_rd_data[5:0]} +
                        {1'b0, w_ram_rd_data[14:9]} - 1'b1;
                    r_desc_end_addr <= DIRECTORY_WORDS +
                        ({5'd0, w_ram_rd_data[5:0]} << 3) +
                        {5'd0, w_ram_rd_data[5:0]} +
                        ({5'd0, w_ram_rd_data[14:9]} << 3) +
                        {5'd0, w_ram_rd_data[14:9]};
                    r_state <= ST_DESC_CHECK;
                end

                ST_DESC_CHECK: begin
                    if (r_desc_step_count == 0) begin
                        // 空目录必须整个 16-bit word 为 0。
                        if ((r_desc_reserved != 0) ||
                            (r_desc_start_step_number != 0))
                            o_error <= 1'b1;
                        o_done  <= 1'b1;
                        r_state <= ST_IDLE;
                    end else if ((r_desc_reserved != 0) ||
                                 (r_desc_step_count > P_MAX_STEPS) ||
                                 (r_desc_last_step_number > MAX_STEP_NUMBER) ||
                                 (r_desc_end_addr > RAM_WORD_COUNT)) begin
                        o_error <= 1'b1;
                        o_done  <= 1'b1;
                        r_state <= ST_IDLE;
                    end else begin
                        r_step_count     <= r_desc_step_count;
                        r_step_index     <= 6'd0;
                        r_step_base_addr <= r_desc_start_addr;
                        r_state          <= ST_STEP_REQUEST;
                    end
                end

                ST_STEP_REQUEST: begin
                    r_next_en_state  <= 128'd0;
                    r_delay_units    <= 16'd0;
                    r_issue_count    <= 4'd1;
                    r_capture_count  <= 4'd0;
                    r_response_valid <= 1'b0;
                    r_ram_rd_en      <= 1'b1;
                    r_ram_rd_addr    <= r_step_base_addr;
                    r_state          <= ST_STEP_STREAM;
                end

                ST_STEP_STREAM: begin
                    if (r_issue_count < 4'd9) begin
                        r_ram_rd_en   <= 1'b1;
                        r_ram_rd_addr <= r_step_base_addr + r_issue_count;
                        r_issue_count <= r_issue_count + 1'b1;
                    end

                    if (r_response_valid) begin
                        case (r_capture_count)
                            4'd0: r_next_en_state[127:112] <= w_ram_rd_data;
                            4'd1: r_next_en_state[111:96]  <= w_ram_rd_data;
                            4'd2: r_next_en_state[95:80]   <= w_ram_rd_data;
                            4'd3: r_next_en_state[79:64]   <= w_ram_rd_data;
                            4'd4: r_next_en_state[63:48]   <= w_ram_rd_data;
                            4'd5: r_next_en_state[47:32]   <= w_ram_rd_data;
                            4'd6: r_next_en_state[31:16]   <= w_ram_rd_data;
                            4'd7: r_next_en_state[15:0]    <= w_ram_rd_data;
                            4'd8: r_delay_units            <= w_ram_rd_data;
                            default: begin end
                        endcase

                        if (r_capture_count == 4'd8)
                            r_state <= ST_APPLY;
                        else
                            r_capture_count <= r_capture_count + 1'b1;
                    end
                end

                ST_APPLY: begin
                    o_en_state           <= r_next_en_state;
                    r_delay_remaining    <= r_delay_units;
                    r_delay_tick_counter <= 32'd0;
                    if (r_delay_units == 0)
                        r_state <= ST_ADVANCE;
                    else
                        r_state <= ST_DELAY;
                end

                ST_DELAY: begin
                    if ((CYCLES_PER_MS <= 1) ||
                        (r_delay_tick_counter + 1'b1 >= CYCLES_PER_MS)) begin
                        r_delay_tick_counter <= 32'd0;
                        if (r_delay_remaining <= 16'd1) begin
                            r_delay_remaining <= 16'd0;
                            r_state           <= ST_ADVANCE;
                        end else begin
                            r_delay_remaining <= r_delay_remaining - 1'b1;
                        end
                    end else begin
                        r_delay_tick_counter <= r_delay_tick_counter + 1'b1;
                    end
                end

                ST_ADVANCE: begin
                    if (r_step_index + 1'b1 < r_step_count) begin
                        r_step_index     <= r_step_index + 1'b1;
                        r_step_base_addr <= r_step_base_addr + 10'd9;
                        r_state          <= ST_STEP_REQUEST;
                    end else begin
                        o_done  <= 1'b1;
                        r_state <= ST_IDLE;
                    end
                end

                default: begin
                    o_error <= 1'b1;
                    r_state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
