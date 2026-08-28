`ifndef CMD_DISPATCHER_DEFS_VH
`define CMD_DISPATCHER_DEFS_VH

/*
 * Dispatcher 与 demo 业务共用的编号定义。
 * CMD 高四位为业务类别，低四位由业务模块解释。
 * 以下命令和错误码为 demo 分配，正式协议确定后在此统一调整。
 * active_module 同时供请求侧 Payload 地址选择和响应侧接口选择使用。
 */
`define COMM_CLASS_PARAM          4'h1
`define COMM_CLASS_CTRL           4'h2

`define COMM_MODULE_NONE          2'd0
`define COMM_MODULE_PARAM         2'd1
`define COMM_MODULE_CTRL          2'd2

`define COMM_CMD_PARAM_READ       8'h10
`define COMM_CMD_PARAM_WRITE      8'h11
`define COMM_CMD_CTRL_READ        8'h20
`define COMM_CMD_CTRL_WRITE       8'h21

`define COMM_STATUS_SUCCESS       8'h00
`define COMM_ERROR_UNKNOWN_CMD    8'h01
`define COMM_ERROR_LENGTH         8'h02
`define COMM_ERROR_PARAM          8'h03

`endif
