`ifndef AD5560_UDP_CMD_DEFS_VH
`define AD5560_UDP_CMD_DEFS_VH
// 以 design/comm/CMD_DEFINITION.md 为准，不沿用旧 Buck 工程 CMD。
`define UDP_CMD_CONFIG_DATA    8'h10
`define UDP_CMD_CONFIG_START   8'h11
`define UDP_CMD_POWER_DATA     8'h20
`define UDP_CMD_POWER_START    8'h21
`define UDP_CMD_SYSTEM_STATUS  8'h41
`define UDP_CMD_TEL_ENABLE     8'h50
`define UDP_CMD_TEL_READ       8'h51
`define UDP_SUCCESS           8'h00
`define UDP_UNKNOWN_CMD       8'h01
`define UDP_LENGTH_ERROR      8'h02
`define UDP_PARAM_ERROR       8'h03
`define UDP_APP_NONE          3'd0
`define UDP_APP_CONFIG        3'd1
`define UDP_APP_POWER         3'd2
`define UDP_APP_TELEMETRY     3'd3
`define UDP_APP_STATUS        3'd4
`endif
