# AD5560 UDP CMD 初版接线与使用

## 接线

板级使用 `ad5560_udp_top`，同一 `i_clk/i_rst_n` 域连接：

```text
UDP/IP RX(byte, valid, length)
  -> udp_frame_parser
  -> udp_cmd_dispatcher
      -> Config/PSE udp_image_application（两份独立实例）
      -> udp_telemetry_application
      -> udp_status_application
  -> 响应MUX / udp_error_response
  -> udp_tx_frame_builder
  -> UDP/IP TX(ready, request, ack, data_valid, data, length)
```

`ad5560_udp_top` 例化 `ad5560_udp_comm`、现有 `ad5560_top` 和 `measurement_manager`。AD4114的 `sample_valid/adc_id/channel/data` 接到顶层四个 `i_sample_*` 端口；不在通信模块里重新例化ADC或调度其SPI。8BUS AD5560物理端口仍由原业务顶层输出。

新源文件在本目录，综合时加入这些 `.v`、将本目录加入include路径，并继续包含原有Config/PSE/Alarm/System/Driver/SPI/CRC、`rtl/samp/measurement_manager.v` 以及所需RAM IP。板级PHY、UDP/IP核、时钟约束和工程顶层选择由具体板级工程连接；本次不改现有PHY工程。

端口约定：

- `i_rx_length` 是真实UDP Payload总字节数，在首个RX字节之前有效；整包字节只送一次。UDP/IP元数据必须和实际字节数一致。
- TX在ready后提出request，ack接受后连续输出整包字节；ready不是逐字节反压。`o_busy` 表示Parser已接受请求、等待业务响应/TX完成，并非Config/PSE后台执行busy。
- TX完整交出最后字节后，`frame_done`释放Parser；主机严格一问一答。请求CMD和SEQ原样回显，SEQ允许回绕。
- 外部调试入口 `i_alarm_clear_req/i_alarm_clear_all/i_fault_reset` 保留，暂未实现相应Alarm/Fault UDP CMD；不用时连接0。

## 已实现命令与语义

正式字段定义仍以 `design/comm/CMD_DEFINITION.md` 为准。

| CMD | 本次实现 |
|---|---|
| 10 | OFFSET为32-bit Record地址；完整检查长度/对齐/范围后逐Word大端写Cfg RAM |
| 11 | 长度与Image CRC提交原Config Manager；CRC完成后回复`00 CRC_OK`，只有正确且System允许时才发一次启动 |
| 20 | OFFSET为16-bit Word地址；大端写PSE RAM |
| 21 | MODE=0/1，Word长度与CRC提交原PSE；正确且READY才启动ON/OFF；回复不等整个时序结束 |
| 50 | 保存128-bit大端Mask，复位默认0；bit n门控通道n的采样写入，禁用保留原缓存 |
| 51 | 根据Read Mask按0..127升序输出每通道六字节，空Mask回复单字节00，全选769字节Payload |
| 41 | 锁存并回复`STATUS SYS_STATE CFG_RESULT SEQ_RESULT FAULT_VECTOR` |

Image CRC错误时响应仍为`00 00`：请求已正常处理，但Image未通过校验，绝不启动；没有自行扩展错误码。未知/未实现CMD为01，长度/对齐错误为02，范围/模式/明显状态不允许为03，错误响应仅含一字节STATUS。

Config可在IDLE/READY启动；PSE仅READY启动，因此复位后先执行成功Config（空Config长度0、CRC=FFFF亦可），再上下电。Config/PSE RAM下载仅在IDLE/READY且目标业务未执行时接受。PSE长度至少覆盖20-word Header、最多2048 word；Config最多1024 Record。业务层不进一步校验Image内部步骤指针或Record位域，上位机须下发合法Image。

Payload最多1024字节，因此一次最多255个Config Record，或511个PSE Word；更大Image分多笔DATA并正确设置OFFSET。Image CRC覆盖整个有效Image，不包含OFFSET/START字段，和外层CMD..PAYLOAD帧CRC分别计算。

参数/字节序/整个目标范围在写入前检查；如果下载中发生Alarm导致权限丢失，本请求返回03，已经完成的Word不回滚。CRC后如状态不再允许启动同样返回03，不会把未接受的启动回复成成功。

## SYSTEM_STATUS

仅导出正式0..8编码。内部DRAIN映射为正在排空业务类别：Config=01，Sequence=03，Alarm或AlarmClear=04，绝不导出09。
CFG/SEQ结果按实际start/done/abort事件保持：00未开始、01执行中、02已完成、03已中止；新一次实际启动覆盖旧结果。Config完成已等待Driver ready；Sequence完成只表示时序流程结束，模拟输出不作稳定承诺。FAULT_VECTOR仍取System原有锁存向量。

## 测量与RAM限制

当前 **V字段只是采样原码，I字段固定0，并不是真实电流测量**。不做V/I切换、Gain/FIN DAC计算、寄存器读改写、Shadow RAM或Driver授权。

`measurement_result_ram` 为128×24简单双口，7-bit地址，A写/B同步读，读延迟1拍且无额外输出寄存器，端口 `dia/addra/cea/clka/dob/addrb/ceb/clkb`。未采样地址用已写标志屏蔽为0；禁用后读到旧缓存是预期行为。同地址读写碰撞结果不保证；一次响应的不同通道不是原子快照。

此外继续使用原 `cfg_ram(1024×32)`、`seq_ram(2048×16)`、`alarm_result_ram(512×16)`、`ip_ram_udp(1024×8)`。Parser/TX分别例化一份ip_ram_udp。验证目录RAM模型仅用于仿真，不能与生成IP同时加入综合。

## 回归

```powershell
& 'D:\04-software\python3.10\python.exe' '.\verification\udp_cmd_cocotb\run_cocotb.py'
```

runner使用真实Config/PSE/Measurement/System/Driver与Parser/TX RTL，自动检查XML failure/error并返回非零。Windows Icarus的中文定义路径会触发VPI解码错误，因此编译各build目录内逐字节相同的ASCII源码快照，源文件路径/哈希与映射均保留。

本轮不实现协议文档中的最近请求去重/响应重放缓存，不实现请求队列、复杂超时恢复或完整Alarm/Fault业务命令。保留Parser原有超时及底层Driver故障处理，不承诺跨重发或跨复位的严格一次执行。
