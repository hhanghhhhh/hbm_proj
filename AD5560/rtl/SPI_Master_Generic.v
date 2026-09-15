/*
Module Name : SPI_Master_Generic
Description : A highly robust, generic, and reusable SPI Master IP.
Features    :
    - Supports all 4 standard SPI modes (CPOL / CPHA).
    - Supports dynamic transmission length (1 to MAX_DATA_WIDTH bits).
    - Intuitive RIGHT-ALIGNED user data interface (internal auto-alignment).
    - Standard Valid/Ready handshake interface.
    - CS decoupled for multi-byte burst transmission.
*/

module SPI_Master_Generic #(
    parameter SYS_CLK_FREQ   = 100_000_000, // System clock frequency (Hz)
    parameter SPI_CLK_FREQ   = 1_000_000,   // SPI clock frequency (Hz)
    parameter MAX_DATA_WIDTH = 32,          // Maximum bits per packet (e.g., 8, 16, 32)
    parameter CPOL           = 0,           // Clock Polarity (0: Idle Low, 1: Idle High)
    parameter CPHA           = 0            // Clock Phase (0: First edge sample, 1: Second edge sample)
)(
    input  wire                         i_sys_clk,
    input  wire                         i_sys_rst_n,
    
    // --- User Interface (MAC Layer) ---
    input  wire                         i_req_valid,      // High to start transmission
    output wire                         o_req_ready,      // High means module is IDLE and ready
    input  wire [15:0]                  i_data_len,       // Number of bits to send (e.g., 8, 16, 32)
    input  wire [MAX_DATA_WIDTH-1:0]    i_tx_data,        // Data to send (Right-aligned, e.g., 8'hA5 placed at [7:0])
    
    output reg                          o_rx_valid,       // 1-cycle pulse when RX data is ready
    output reg  [MAX_DATA_WIDTH-1:0]    o_rx_data,        // Received data (Naturally right-aligned)
    
    input  wire                         i_spi_cs_n,       // CS control from MAC layer (pass-through)
    
    // --- SPI Physical Interface (PHY Layer) ---
    output wire                         o_spi_cs,         // Connect to physical CS pin
    output reg                          o_spi_sck,        // Connect to physical SCK pin
    output reg                          o_spi_mosi,       // Connect to physical MOSI pin
    input  wire                         i_spi_miso        // Connect to physical MISO pin
);

//-------------------------------------------------------------------
// 1. Clock Divider Engine (Generates a tick at 2x SPI_CLK)
//-------------------------------------------------------------------
localparam CLK_DIV_TMP = SYS_CLK_FREQ / (SPI_CLK_FREQ * 2);
// Ensure divider is at least 1 (requires SYS_CLK >= 2 * SPI_CLK)
localparam DIV_RATIO   = (CLK_DIV_TMP > 0) ? CLK_DIV_TMP : 1;

reg [15:0]  div_cnt;
wire        sck_tick;

//-------------------------------------------------------------------
// 2. FSM States & Registers
//-------------------------------------------------------------------
localparam STATE_IDLE = 2'd0;
localparam STATE_WORK = 2'd1;
localparam STATE_DONE = 2'd2;

reg [1:0]                   state;
reg [15:0]                  phase_cnt;      // Counts phases (2 phases per SPI bit)
reg [15:0]                  current_len;    // Latched data length
reg [MAX_DATA_WIDTH-1:0]    tx_shifter;     // Internal TX shift register
reg [MAX_DATA_WIDTH-1:0]    rx_shifter;     // Internal RX shift register

//-------------------------------------------------------------------
// 3. Mode Phase Control Logic (The core logic for CPOL/CPHA)
//-------------------------------------------------------------------
// CPHA=0: Sample on even phases (0, 2, 4...), Shift on odd phases (1, 3, 5...)
// CPHA=1: Sample on odd phases (1, 3, 5...), Shift on even phases (0, 2, 4...)
wire sample_en = (CPHA == 0) ? (phase_cnt[0] == 1'b0) : (phase_cnt[0] == 1'b1);
wire shift_en  = (CPHA == 0) ? (phase_cnt[0] == 1'b1) : (phase_cnt[0] == 1'b0);

// Tick generation: Active only in WORK state
always @(posedge i_sys_clk or negedge i_sys_rst_n) begin
    if (!i_sys_rst_n) begin
        div_cnt <= 16'd0;
    end else if (state == STATE_WORK) begin
        if (div_cnt == DIV_RATIO - 1)
            div_cnt <= 16'd0;
        else
            div_cnt <= div_cnt + 16'd1;
    end else begin
        div_cnt <= 16'd0;
    end
end
assign sck_tick = (state == STATE_WORK) && (div_cnt == DIV_RATIO - 1);

//-------------------------------------------------------------------
// 4. Main State Machine & Shift Logic
//-------------------------------------------------------------------
always @(posedge i_sys_clk or negedge i_sys_rst_n) begin
    if (!i_sys_rst_n) begin
        state       <= STATE_IDLE;
        o_spi_sck   <= CPOL[0];
        o_spi_mosi  <= 1'b0;
        o_rx_valid  <= 1'b0;
        o_rx_data   <= {MAX_DATA_WIDTH{1'b0}};
        phase_cnt   <= 16'd0;
        current_len <= 16'd0;
        tx_shifter  <= {MAX_DATA_WIDTH{1'b0}};
        rx_shifter  <= {MAX_DATA_WIDTH{1'b0}};
    end 
    else begin
        case (state)
            // --------------------------------------------------
            // STATE_IDLE: Wait for transmission request
            // --------------------------------------------------
            STATE_IDLE: begin
                o_rx_valid <= 1'b0;
                o_spi_sck  <= CPOL[0];
                
                if (i_req_valid) begin
                    state       <= STATE_WORK;
                    current_len <= i_data_len;
                    phase_cnt   <= 16'd0;
                    
                    // Secret Sauce 1: Auto Left-Align the TX data internally!
                    // This allows user to input right-aligned data, keeping interface clean.
                    tx_shifter  <= i_tx_data << (MAX_DATA_WIDTH - i_data_len);
                    
                    // For CPHA=0, MOSI must be setup before the very first clock edge.
                    if (CPHA == 0) begin
                        o_spi_mosi <= i_tx_data[i_data_len - 16'd1]; 
                    end
                end
            end
            
            // --------------------------------------------------
            // STATE_WORK: Clock Toggling and Bit Shifting
            // --------------------------------------------------
            STATE_WORK: begin
                if (sck_tick) begin
                    phase_cnt <= phase_cnt + 16'd1;
                    
                    // Toggle SCK on every tick
                    o_spi_sck <= ~o_spi_sck;
                    
                    // --- MISO Sampling Phase ---
                    if (sample_en) begin
                        // Received data enters from LSB. Over N shifts, it perfectly right-aligns.
                        rx_shifter <= {rx_shifter[MAX_DATA_WIDTH-2:0], i_spi_miso};
                    end
                    
                    // --- MOSI Shifting Phase ---
                    if (shift_en) begin
                        if (CPHA == 1 && phase_cnt == 16'd0) begin
                            // First shift action for CPHA=1 merely drives the MSB, no shift needed yet
                            o_spi_mosi <= tx_shifter[MAX_DATA_WIDTH-1];
                        end else begin
                            // Shift register left, and output the NEW MSB (which is bit MAX-2 prior to shift)
                            tx_shifter <= {tx_shifter[MAX_DATA_WIDTH-2:0], 1'b0};
                            o_spi_mosi <= tx_shifter[MAX_DATA_WIDTH-2];
                        end
                    end
                    
                    // --- End Condition ---
                    // Each bit takes 2 phases. Total phases = len * 2
                    if (phase_cnt == (current_len << 1) - 16'd1) begin
                        state <= STATE_DONE;
                    end
                end
            end
            
            // --------------------------------------------------
            // STATE_DONE: Output Valid Pulse and Restore IDLE
            // --------------------------------------------------
            STATE_DONE: begin
                o_spi_sck  <= CPOL[0];  // Ensure clock returns to IDLE state safely
                o_rx_valid <= 1'b1;     // Generate 1-cycle high pulse
                o_rx_data  <= rx_shifter;
                state      <= STATE_IDLE;
            end
            
            default: state <= STATE_IDLE;
        endcase
    end
end

//-------------------------------------------------------------------
// 5. Output Assignments
//-------------------------------------------------------------------
assign o_req_ready = (state == STATE_IDLE);
assign o_spi_cs    = i_spi_cs_n; // Pass-through for MAC-level control

endmodule