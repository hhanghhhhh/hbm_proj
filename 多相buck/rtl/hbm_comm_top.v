`timescale 1ns / 1ps

/*
 * PH1A60 板级通信顶层。
 * 直接集成 UART 通信链路、配置/遥测业务和八路 I2C 单元。
 * 板上第九路 I2C 仅保留接口，暂不接入业务逻辑。
 */
module hbm_comm_top (
    input  wire         i_clk_25m,

    input  wire         i_uart_rx,
    output wire         o_uart_tx,
    output wire         o_rs485_re_n,
    output wire         o_rs485_de,
    input  wire [5:0]   i_rs485_address,

    output wire [111:0] o_jwh_power_enable,
    input  wire [6:0]   i_jwh_alert,
    inout  wire [8:0]   io_i2c_scl,
    inout  wire [8:0]   io_i2c_sda,

    input  wire [6:0]   i_adc_error,
    output wire [6:0]   o_adc_cs_n,
    output wire [6:0]   o_adc_sync,
    input  wire [6:0]   i_adc_miso,
    output wire [6:0]   o_adc_mosi,
    output wire [6:0]   o_adc_sclk,

    input  wire         i_trigger_in,
    output wire         o_trigger_out,
    output wire         o_dps_sync,
    output wire         o_sync_oe,
    output wire [1:0]   o_led
);

    localparam integer BUS_COUNT = 8;
    localparam [7:0]   CONFIG_ALLOWED = 8'hFF;
    localparam integer CLK_FREQ_HZ = 100000000;
    localparam integer BAUD_RATE = 460800;
    localparam integer TRANSACTION_TIMEOUT_MS = 1000;
    localparam integer I2C_BAUD_RATE = 400000;
    localparam         TCA_ENABLE = 1'b0;
    localparam [6:0]   JWH_ADDR_BASE = 7'h60;

    wire        clk_100m;
    wire        pll_locked;
    wire        sys_rst_n;
    wire [7:0]  rx_byte;
    wire        rx_valid;
    wire        rx_error;
    wire [7:0]  tx_byte;
    wire        tx_valid;
    wire        tx_ready;
    wire        tx_done;
    wire        rs485_tx_enable;
    wire [7:0]  local_addr;

    wire        frame_valid;
    wire [7:0]  frame_addr;
    wire [7:0]  frame_cmd;
    wire [7:0]  frame_seq;
    wire [15:0] frame_length;
    wire [10:0] parser_rd_addr;
    wire [7:0]  parser_rd_data;
    wire        rx_timeout;
    wire        length_error;
    wire        crc_error;
    wire        addr_error;
    wire        transaction_timeout;

    wire [7:0]  req_cmd;
    wire [7:0]  req_seq;
    wire [15:0] req_length;
    wire [7:0]  payload_rd_data;
    wire [3:0]  active_module;
    wire        param_req_valid;
    wire        ctrl_req_valid;
    wire        config_req_valid;
    wire        telemetry_req_valid;
    wire [10:0] ctrl_payload_rd_addr;
    wire [10:0] config_payload_rd_addr;
    wire [10:0] telemetry_payload_rd_addr;
    wire        dispatcher_error_valid;
    wire [7:0]  dispatcher_error_code;

    wire        ctrl_rsp_wr_en;
    wire [10:0] ctrl_rsp_wr_addr;
    wire [7:0]  ctrl_rsp_wr_data;
    wire [15:0] ctrl_rsp_length;
    wire        ctrl_rsp_valid;
    wire        ctrl_error_valid;
    wire [7:0]  ctrl_error_code;
    wire [127:0] debug_en_state;
    wire        seq_ram_wr_en;
    wire [9:0]  seq_ram_wr_addr;
    wire [15:0] seq_ram_wr_data;
    wire [3:0]  sequence_id;
    wire        sequence_start;
    wire        sequence_ready;
    wire        sequence_done;
    wire        sequence_error;
    wire [127:0] sequence_en_state;
    wire [3:0]  sequence_debug_state;

    wire        config_rsp_wr_en;
    wire [10:0] config_rsp_wr_addr;
    wire [7:0]  config_rsp_wr_data;
    wire [15:0] config_rsp_length;
    wire        config_rsp_valid;
    wire        config_error_valid;
    wire [7:0]  config_error_code;

    wire        telemetry_rsp_wr_en;
    wire [10:0] telemetry_rsp_wr_addr;
    wire [7:0]  telemetry_rsp_wr_data;
    wire [15:0] telemetry_rsp_length;
    wire        telemetry_rsp_valid;
    wire        telemetry_error_valid;
    wire [7:0]  telemetry_error_code;
    wire [127:0] telemetry_enable;
    wire        tel_rd_en;
    wire [2:0]  tel_rd_bus;
    wire [8:0]  tel_rd_addr;
    wire [31:0] tel_rd_data_selected;

    wire        error_valid;
    wire [7:0]  error_code;
    wire        error_rsp_wr_en;
    wire [10:0] error_rsp_wr_addr;
    wire [7:0]  error_rsp_wr_data;
    wire [15:0] error_rsp_length;
    wire        error_rsp_valid;

    wire        rsp_wr_en;
    wire [10:0] rsp_wr_addr;
    wire [7:0]  rsp_wr_data;
    wire [15:0] rsp_length;
    wire        rsp_valid;

    wire [2:0]  bus_sel;
    wire        cfg_ram_wr_en;
    wire [9:0]  cfg_ram_wr_addr;
    wire [31:0] cfg_ram_wr_data;
    wire        cfg_start;
    wire [5:0]  cfg_device_id;
    wire [10:0] cfg_record_count;
    wire        cfg_store_after;
    wire        cfg_config_mode;
    wire        cfg_result_rd_en;
    wire [9:0]  cfg_result_rd_addr;
    wire [7:0]  bus_ready;
    wire [127:0] cfg_result_rd_data;
    wire [255:0] tel_rd_data;
    wire        selected_ready;
    wire [15:0] selected_cfg_result_rd_data;
    reg  [2:0]  tel_rd_bus_latched;

    wire [7:0]   cfg_resp_valid;
    wire [7:0]   cfg_resp_error;
    wire [31:0]  cfg_sys_error_code;
    wire [39:0]  cfg_bus_error_code;
    wire [79:0]  cfg_error_index;
    wire [127:0] cfg_last_mtp_crc;
    reg  [7:0]   cfg_ok;
    integer cfg_ok_index;

    PLL_0 u_pll (
        .refclk   (i_clk_25m),
        .reset    (1'b0),
        .lock     (pll_locked),
        .clk0_out (clk_100m)
    );

    reset_release_sync u_reset_release (
        .clk         (clk_100m),
        .async_ready (pll_locked),
        .rst_n       (sys_rst_n)
    );

    UART_RX_Direct #(
        .SYS_CLK_FREQ (CLK_FREQ_HZ),
        .BAUD_RATE    (BAUD_RATE)
    ) u_uart_rx (
        .i_sys_clk   (clk_100m),
        .i_sys_rst_n (sys_rst_n),
        .i_uart_rx   (i_uart_rx),
        .o_rx_valid  (rx_valid),
        .o_rx_data   (rx_byte),
        .o_rx_err    (rx_error)
    );

    UART_TX_Direct #(
        .SYS_CLK_FREQ (CLK_FREQ_HZ),
        .BAUD_RATE    (BAUD_RATE)
    ) u_uart_tx (
        .i_sys_clk   (clk_100m),
        .i_sys_rst_n (sys_rst_n),
        .i_tx_valid  (tx_valid),
        .o_tx_ready  (tx_ready),
        .i_tx_data   (tx_byte),
        .o_uart_tx   (o_uart_tx)
    );

    frame_parser #(
        .CLK_FREQ_HZ            (CLK_FREQ_HZ),
        .BAUD_RATE              (BAUD_RATE),
        .MAX_PAYLOAD_LENGTH     (2048),
        .TRANSACTION_TIMEOUT_MS (TRANSACTION_TIMEOUT_MS)
    ) u_frame_parser (
        .i_clk                 (clk_100m),
        .i_rst_n               (sys_rst_n),
        .i_rx_byte             (rx_byte),
        .i_rx_valid            (rx_valid),
        .i_local_addr          (local_addr),
        .i_frame_done          (tx_done),
        .o_frame_valid         (frame_valid),
        .o_addr                (frame_addr),
        .o_cmd                 (frame_cmd),
        .o_seq                 (frame_seq),
        .o_payload_length      (frame_length),
        .i_payload_rd_addr     (parser_rd_addr),
        .o_payload_rd_data     (parser_rd_data),
        .o_rx_timeout          (rx_timeout),
        .o_length_error        (length_error),
        .o_crc_error           (crc_error),
        .o_addr_error          (addr_error),
        .o_transaction_timeout (transaction_timeout)
    );

    cmd_dispatcher u_cmd_dispatcher (
        .i_clk                       (clk_100m),
        .i_rst_n                     (sys_rst_n),
        .i_abort                     (transaction_timeout),
        .i_frame_valid               (frame_valid),
        .i_frame_cmd                 (frame_cmd),
        .i_frame_seq                 (frame_seq),
        .i_frame_length              (frame_length),
        .o_req_cmd                   (req_cmd),
        .o_req_seq                   (req_seq),
        .o_req_length                (req_length),
        .o_payload_rd_data           (payload_rd_data),
        .o_param_req_valid           (param_req_valid),
        .o_ctrl_req_valid            (ctrl_req_valid),
        .o_config_req_valid          (config_req_valid),
        .o_telemetry_req_valid       (telemetry_req_valid),
        .o_active_module             (active_module),
        .i_param_payload_rd_addr     (11'd0),
        .i_ctrl_payload_rd_addr      (ctrl_payload_rd_addr),
        .i_config_payload_rd_addr    (config_payload_rd_addr),
        .i_telemetry_payload_rd_addr (telemetry_payload_rd_addr),
        .o_payload_rd_addr           (parser_rd_addr),
        .i_payload_rd_data           (parser_rd_data),
        .o_error_valid               (dispatcher_error_valid),
        .o_error_code                (dispatcher_error_code)
    );

    en_control_application u_en_control_application (
        .i_clk             (clk_100m),
        .i_rst_n           (sys_rst_n),
        .i_abort           (transaction_timeout),
        .i_req_valid       (ctrl_req_valid),
        .i_req_cmd         (req_cmd),
        .i_req_seq         (req_seq),
        .i_req_length      (req_length),
        .o_payload_rd_addr (ctrl_payload_rd_addr),
        .i_payload_rd_data (payload_rd_data),
        .o_rsp_wr_en       (ctrl_rsp_wr_en),
        .o_rsp_wr_addr     (ctrl_rsp_wr_addr),
        .o_rsp_wr_data     (ctrl_rsp_wr_data),
        .o_rsp_length      (ctrl_rsp_length),
        .o_rsp_valid       (ctrl_rsp_valid),
        .o_error_valid     (ctrl_error_valid),
        .o_error_code      (ctrl_error_code),
        .o_en_state        (debug_en_state),
        .o_seq_ram_wr_en   (seq_ram_wr_en),
        .o_seq_ram_wr_addr (seq_ram_wr_addr),
        .o_seq_ram_wr_data (seq_ram_wr_data),
        .o_sequence_id     (sequence_id),
        .o_sequence_start  (sequence_start)
    );

    en_sequence_controller #(
        .P_SYS_CLK_FREQ   (CLK_FREQ_HZ),
        .P_SEQUENCE_COUNT (2),
        .P_MAX_STEPS      (32),
        .P_RAM_ADDR_WIDTH (10)
    ) u_en_sequence_controller (
        .i_clk           (clk_100m),
        .i_rst_n         (sys_rst_n),
        .i_clear         (1'b0),
        .i_emergency_off (1'b0),
        .i_start         (sequence_start),
        .o_ready         (sequence_ready),
        .i_sequence_id   (sequence_id),
        .i_ram_wr_en     (seq_ram_wr_en),
        .i_ram_wr_addr   (seq_ram_wr_addr),
        .i_ram_wr_data   (seq_ram_wr_data),
        .o_done          (sequence_done),
        .o_error         (sequence_error),
        .o_en_state      (sequence_en_state),
        .o_debug_state   (sequence_debug_state)
    );

    telemetry_application u_telemetry_application (
        .i_clk              (clk_100m),
        .i_rst_n            (sys_rst_n),
        .i_abort            (transaction_timeout),
        .i_req_valid        (telemetry_req_valid),
        .i_req_cmd          (req_cmd),
        .i_req_seq          (req_seq),
        .i_req_length       (req_length),
        .o_payload_rd_addr  (telemetry_payload_rd_addr),
        .i_payload_rd_data  (payload_rd_data),
        .o_rsp_wr_en        (telemetry_rsp_wr_en),
        .o_rsp_wr_addr      (telemetry_rsp_wr_addr),
        .o_rsp_wr_data      (telemetry_rsp_wr_data),
        .o_rsp_length       (telemetry_rsp_length),
        .o_rsp_valid        (telemetry_rsp_valid),
        .o_error_valid      (telemetry_error_valid),
        .o_error_code       (telemetry_error_code),
        .o_telemetry_enable (telemetry_enable),
        .o_tel_rd_en        (tel_rd_en),
        .o_tel_rd_bus       (tel_rd_bus),
        .o_tel_rd_addr      (tel_rd_addr),
        .i_tel_rd_data      (tel_rd_data_selected)
    );

    assign selected_ready = bus_ready[bus_sel];
    assign selected_cfg_result_rd_data =
        cfg_result_rd_data[bus_sel*16 +: 16];
    assign tel_rd_data_selected =
        tel_rd_data[tel_rd_bus_latched*32 +: 32];

    // 遥测 RAM 为同步读，锁存发起读取时选择的总线。
    always @(posedge clk_100m or negedge sys_rst_n) begin
        if (!sys_rst_n)
            tel_rd_bus_latched <= 3'd0;
        else if (tel_rd_en)
            tel_rd_bus_latched <= tel_rd_bus;
    end

    config_application #(
        .BUS_COUNT (BUS_COUNT)
    ) u_config_application (
        .i_clk                   (clk_100m),
        .i_rst_n                 (sys_rst_n),
        .i_abort                 (transaction_timeout),
        .i_req_valid             (config_req_valid),
        .i_req_cmd               (req_cmd),
        .i_req_seq               (req_seq),
        .i_req_length            (req_length),
        .o_payload_rd_addr       (config_payload_rd_addr),
        .i_payload_rd_data       (payload_rd_data),
        .o_rsp_wr_en             (config_rsp_wr_en),
        .o_rsp_wr_addr           (config_rsp_wr_addr),
        .o_rsp_wr_data           (config_rsp_wr_data),
        .o_rsp_length            (config_rsp_length),
        .o_rsp_valid             (config_rsp_valid),
        .o_error_valid           (config_error_valid),
        .o_error_code            (config_error_code),
        .o_bus_sel               (bus_sel),
        .o_cfg_ram_wr_en         (cfg_ram_wr_en),
        .o_cfg_ram_wr_addr       (cfg_ram_wr_addr),
        .o_cfg_ram_wr_data       (cfg_ram_wr_data),
        .o_cfg_start             (cfg_start),
        .i_cfg_ready             (selected_ready),
        .o_cfg_device_id         (cfg_device_id),
        .o_cfg_record_count      (cfg_record_count),
        .o_cfg_store_after       (cfg_store_after),
        .o_cfg_config_mode       (cfg_config_mode),
        .o_cfg_result_rd_en      (cfg_result_rd_en),
        .o_cfg_result_rd_addr    (cfg_result_rd_addr),
        .i_cfg_result_rd_data    (selected_cfg_result_rd_data),
        .i_cfg_ok                (cfg_ok)
    );

    genvar bus_index;
    generate
        for (bus_index = 0; bus_index < BUS_COUNT;
             bus_index = bus_index + 1) begin : g_i2c_bus
            localparam [2:0] BUS_ID = bus_index;
            wire bus_selected;

            assign bus_selected = (bus_sel == BUS_ID);

            i2c_bus_unit #(
                .CLK_FREQ_HZ   (CLK_FREQ_HZ),
                .I2C_BAUD_RATE (I2C_BAUD_RATE),
                .TCA_ENABLE    (TCA_ENABLE),
                .JWH_ADDR_BASE (JWH_ADDR_BASE)
            ) u_i2c_bus_unit (
                .i_clk                    (clk_100m),
                .i_rst_n                  (sys_rst_n),
                .i_config_allowed         (CONFIG_ALLOWED[bus_index]),
                .i_telemetry_enable       (
                    telemetry_enable[bus_index*16 +: 16]),
                .i_cfg_ram_wr_en          (cfg_ram_wr_en && bus_selected),
                .i_cfg_ram_wr_addr        (cfg_ram_wr_addr),
                .i_cfg_ram_wr_data        (cfg_ram_wr_data),
                .i_cfg_start              (cfg_start && bus_selected),
                .o_cfg_ready              (bus_ready[bus_index]),
                .i_cfg_device_id          (cfg_device_id),
                .i_cfg_record_count       (cfg_record_count),
                .i_cfg_store_after        (cfg_store_after),
                .i_cfg_config_mode        (cfg_config_mode),
                .i_cfg_result_rd_en       (
                    cfg_result_rd_en && bus_selected),
                .i_cfg_result_rd_addr     (cfg_result_rd_addr),
                .o_cfg_result_rd_data     (
                    cfg_result_rd_data[bus_index*16 +: 16]),
                .i_tel_rd_en              (
                    tel_rd_en && (tel_rd_bus == BUS_ID)),
                .i_tel_rd_addr            (tel_rd_addr),
                .o_tel_rd_data            (
                    tel_rd_data[bus_index*32 +: 32]),
                .o_cfg_resp_valid         (cfg_resp_valid[bus_index]),
                .o_cfg_resp_error         (cfg_resp_error[bus_index]),
                .o_cfg_sys_error_code     (
                    cfg_sys_error_code[bus_index*4 +: 4]),
                .o_cfg_bus_error_code     (
                    cfg_bus_error_code[bus_index*5 +: 5]),
                .o_cfg_error_index        (
                    cfg_error_index[bus_index*10 +: 10]),
                .o_cfg_last_mtp_crc       (
                    cfg_last_mtp_crc[bus_index*16 +: 16]),
                .io_i2c_scl               (io_i2c_scl[bus_index]),
                .io_i2c_sda               (io_i2c_sda[bus_index])
            );
        end
    endgenerate

    // cfg_ok 表示各路配置任务是否已完成：启动时清零，响应时置位。
    always @(posedge clk_100m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            cfg_ok <= 8'd0;
        end else begin
            if (cfg_start)
                cfg_ok[bus_sel] <= 1'b0;

            for (cfg_ok_index = 0; cfg_ok_index < BUS_COUNT;
                 cfg_ok_index = cfg_ok_index + 1) begin
                if (cfg_resp_valid[cfg_ok_index])
                    cfg_ok[cfg_ok_index] <= 1'b1;
            end
        end
    end

    assign error_valid = dispatcher_error_valid || ctrl_error_valid ||
                         config_error_valid || telemetry_error_valid;
    assign error_code = dispatcher_error_valid ? dispatcher_error_code :
                        ctrl_error_valid ? ctrl_error_code :
                        config_error_valid ? config_error_code :
                        telemetry_error_code;

    error_response_generator u_error_response_generator (
        .i_clk         (clk_100m),
        .i_rst_n       (sys_rst_n),
        .i_abort       (transaction_timeout),
        .i_error_valid (error_valid),
        .i_error_code  (error_code),
        .o_rsp_wr_en   (error_rsp_wr_en),
        .o_rsp_wr_addr (error_rsp_wr_addr),
        .o_rsp_wr_data (error_rsp_wr_data),
        .o_rsp_length  (error_rsp_length),
        .o_rsp_valid   (error_rsp_valid)
    );

    response_buffer u_response_buffer (
        .i_active_module             (active_module),
        .i_param_rsp_wr_en           (1'b0),
        .i_param_rsp_wr_addr         (11'd0),
        .i_param_rsp_wr_data         (8'd0),
        .i_param_rsp_length          (16'd0),
        .i_param_rsp_valid           (1'b0),
        .i_ctrl_rsp_wr_en            (ctrl_rsp_wr_en),
        .i_ctrl_rsp_wr_addr          (ctrl_rsp_wr_addr),
        .i_ctrl_rsp_wr_data          (ctrl_rsp_wr_data),
        .i_ctrl_rsp_length           (ctrl_rsp_length),
        .i_ctrl_rsp_valid            (ctrl_rsp_valid),
        .i_config_rsp_wr_en          (config_rsp_wr_en),
        .i_config_rsp_wr_addr        (config_rsp_wr_addr),
        .i_config_rsp_wr_data        (config_rsp_wr_data),
        .i_config_rsp_length         (config_rsp_length),
        .i_config_rsp_valid          (config_rsp_valid),
        .i_telemetry_rsp_wr_en       (telemetry_rsp_wr_en),
        .i_telemetry_rsp_wr_addr     (telemetry_rsp_wr_addr),
        .i_telemetry_rsp_wr_data     (telemetry_rsp_wr_data),
        .i_telemetry_rsp_length      (telemetry_rsp_length),
        .i_telemetry_rsp_valid       (telemetry_rsp_valid),
        .i_error_rsp_wr_en           (error_rsp_wr_en),
        .i_error_rsp_wr_addr         (error_rsp_wr_addr),
        .i_error_rsp_wr_data         (error_rsp_wr_data),
        .i_error_rsp_length          (error_rsp_length),
        .i_error_rsp_valid           (error_rsp_valid),
        .o_rsp_wr_en                 (rsp_wr_en),
        .o_rsp_wr_addr               (rsp_wr_addr),
        .o_rsp_wr_data               (rsp_wr_data),
        .o_rsp_length                (rsp_length),
        .o_rsp_valid                 (rsp_valid)
    );

    tx_frame_builder #(
        .CLK_FREQ_HZ         (CLK_FREQ_HZ),
        .RS485_PRE_DELAY_US  (10),
        .RS485_POST_DELAY_US (1)
    ) u_tx_frame_builder (
        .i_clk         (clk_100m),
        .i_rst_n       (sys_rst_n),
        .i_abort       (transaction_timeout),
        .i_rsp_wr_en   (rsp_wr_en),
        .i_rsp_wr_addr (rsp_wr_addr),
        .i_rsp_wr_data (rsp_wr_data),
        .i_rsp_length  (rsp_length),
        .i_rsp_valid   (rsp_valid),
        .i_req_addr    (frame_addr),
        .i_req_cmd     (frame_cmd),
        .i_req_seq     (frame_seq),
        .o_tx_byte     (tx_byte),
        .o_tx_valid    (tx_valid),
        .i_tx_ready    (tx_ready),
        .o_rs485_tx_en (rs485_tx_enable),
        .o_tx_done     (tx_done)
    );

    // RS485 发送时同时使能驱动器并关闭接收器。
    assign local_addr = {2'd0, i_rs485_address};
    assign o_rs485_de   = rs485_tx_enable;
    assign o_rs485_re_n = rs485_tx_enable;

    // 暂不处理两个 EN 状态源的竞争，外部仍使用直接控制状态。
    assign o_jwh_power_enable = debug_en_state[111:0];

    // 第九路 I2C 预留，当前保持开漏释放状态。
    assign io_i2c_scl[8] = 1'bz;
    assign io_i2c_sda[8] = 1'bz;

    // 以下板级接口暂未加入业务逻辑，输出保持安全空闲值。
    assign o_spi_mosi    = 1'b0;
    assign io_spi_data   = 2'bzz;
    assign o_adc_cs_n    = 7'h7F;
    assign o_adc_sync    = 7'd0;
    assign o_adc_mosi    = 7'd0;
    assign o_adc_sclk    = 7'd0;
    assign o_trigger_out = 1'b0;
    assign o_dps_sync    = 1'b0;
    assign o_sync_oe     = 1'b0;
    assign o_led         = 2'b00;

endmodule
