`ifndef JWH6374_COMMON_DEFS_VH
`define JWH6374_COMMON_DEFS_VH

// ============================================================================
// JWH6374 上层 PMBus 操作类型
// ============================================================================
// 这些编码在 bus service、bus controller 和 JWH transaction controller
// 之间传递。修改编码时必须保持所有接口一致。
`define JWH_OP_SEND_BYTE   3'd0
`define JWH_OP_WRITE_BYTE  3'd1
`define JWH_OP_WRITE_WORD  3'd2
`define JWH_OP_READ_BYTE   3'd3
`define JWH_OP_READ_WORD   3'd4
`define JWH_OP_ARA         3'd5

// ============================================================================
// JWH6374事务错误码（jwh6374_controller输出，4 bit）
// ============================================================================
`define JWH_ERR_NONE        4'd0
`define JWH_ERR_NACK_ADDR   4'd1
`define JWH_ERR_NACK_CMD    4'd2
`define JWH_ERR_NACK_DATA   4'd3
`define JWH_ERR_PEC         4'd4
`define JWH_ERR_TIMEOUT     4'd5
`define JWH_ERR_INVALID_OP  4'd6

// ============================================================================
// 单物理总线扩展错误码（bus controller/service之间传递，5 bit）
// ============================================================================
// 0..6沿用上面的JWH事务错误码；8..11由bus controller产生。
`define JWH_BUS_ERR_NONE               5'd0
`define JWH_BUS_ERR_TCA                5'd8
`define JWH_BUS_ERR_TIMEOUT_RECOVERED  5'd9
`define JWH_BUS_ERR_CLEAR_FAILED       5'd10
`define JWH_BUS_ERR_INVALID_CHANNEL    5'd11

// ============================================================================
// i2c_master_core Token 命令类型
// ============================================================================
// 这些编码由 TCA/JWH controller 产生，由 i2c_master_core 执行。
`define I2C_CMD_START      3'b001
`define I2C_CMD_WRITE      3'b010
`define I2C_CMD_READ       3'b011
`define I2C_CMD_STOP       3'b100
`define I2C_CMD_BUS_CLEAR  3'b101

`endif
