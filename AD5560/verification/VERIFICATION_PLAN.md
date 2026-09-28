# AD5560 FPGA Verification Plan




## 5. AD5560 Driver 验证

Driver 是寄存器事务和 AD5560 专用时序的边界，重点验证命令锁存、SYNC 映射、读写帧、BUSY 和 fault。

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| DRV-001 | 空闲 ready | reset 后无 fault | `cmd_ready=1` |
| DRV-002 | 普通写 | 发 1 笔 write | 24-bit 帧内容正确 |
| DRV-003 | 参数锁存 | 握手后立即改变输入字段 | 当前事务仍使用握手时参数 |
| DRV-004 | Device 选择 | 遍历 DEV0~DEV15 | 仅对应一路 SYNC 拉低 |
| DRV-005 | SYNC 独占 | 连续随机事务 | 任意时刻最多一路 SYNC 为低 |
| DRV-006 | 写后保护 | SPI done 后控制 BUSY | 不在保护时间前误判 |
| DRV-007 | BUSY 正常结束 | BUSY 正常变化 | 最终重新 ready |
| DRV-008 | BUSY 无低脉冲 | 保护时间结束时 BUSY 已高 | 允许正常完成 |
| DRV-009 | BUSY timeout | BUSY 持续异常 | sticky `bus_fault=1` |
| DRV-010 | fault 后阻塞 | bus_fault 已置位 | `cmd_ready=0`，不接新命令 |
| DRV-011 | fault clear | 发 `bus_fault_clear` | fault 清除并恢复 idle |
| DRV-012 | 普通读 | 发 read | 自动完成两帧 readback |
| DRV-013 | Read frame 2 | 读事务 | 第 2 帧使用 NOP |
| DRV-014 | Read 间隔 | 两 readback frame | SYNC high time 满足设计值 |
| DRV-015 | rsp 返回 | 注入 MISO 数据 | `rsp_valid` 单周期且数据正确 |
| DRV-016 | 连续请求 | ready 后立即下一笔 | 两事务不串扰 |
| DRV-017 | reset | 各状态 reset | SYNC 全高、fault 清除、回 idle |

Driver 时序检查至少包括：

- CS/SYNC setup；
- CS/SYNC hold；
- 普通 transaction SYNC high time；
- write 后 BUSY 检测保护时间；
- readback 两帧间隔；
- SDO high-Z 保护间隔。

### Driver 在线检查项

以下检查优先由 cocotb monitor / checker 持续执行：

```text
A-DRV-001: 任意时刻最多一路 SYNC 为低
A-DRV-002: bus_fault=1 -> cmd_ready=0
A-DRV-003: cmd_valid && !cmd_ready 时，上层命令若要求保持，则 Driver 不可误采样
A-DRV-004: rsp_valid 仅对应已经接受的 READ 请求
A-DRV-005: WRITE 不产生伪 rsp_valid
A-DRV-006: fault clear 后 Driver 最终可重新 ready
```

---

## 6. Config Manager 验证

重点验证 Config RAM 顺序读取、valid/ready backpressure、最后完成屏障以及 abort。

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| CFG-001 | 单记录 | count=1 | 正确产生 1 笔 write |
| CFG-002 | 多记录 | 多条不同 BUS/DEV | 严格按 RAM 顺序提交 |
| CFG-003 | 字段解析 | 特定 RAM 数据 | BUS/DEV/ADDR/DATA 正确 |
| CFG-004 | ready 一直高 | N 条记录 | 连续正确推进 |
| CFG-005 | backpressure | 当前目标 Driver ready=0 | valid/数据保持，不丢记录 |
| CFG-006 | BUS 切换 | 相邻记录不同 BUS | 使用对应 BUS ready |
| CFG-007 | 最后一条提交 | 最后一条握手 | 不立即 cfg_done |
| CFG-008 | 完成屏障 | 最后一条后部分 BUS busy | 等到 `cfg_bus_ready=FF` 才 done |
| CFG-009 | cfg_done 脉冲 | 正常完成 | 仅 1 clk |
| CFG-010 | abort 等待阶段 | 任意记录中 abort | 停止继续派发，busy 清除 |
| CFG-011 | abort valid 未握手 | ready=0 时 abort | 未提交命令被取消 |
| CFG-012 | abort 已握手 | 握手后 abort | 已交给 Driver 的事务不撤销 |
| CFG-013 | count=0 | 空配置表 | 不产生 Driver 命令，直接 cfg_done |
| CFG-014 | reset | 执行中 reset | 回 idle，不残留 valid |
| CFG-015 | busy 时重复 start | cfg_busy=1 时再次 cfg_start | 忽略，不重启、不改变当前进度 |

### Config 在线检查项

```text
A-CFG-001: 未发生 valid&&ready -> record index 不推进
A-CFG-002: cfg_record_count!=0 的正常流程中，cfg_done -> cfg_bus_ready == 8'hFF
A-CFG-003: cfg_done -> 所有记录均已完成提交
A-CFG-004: cfg_abort 后不得再产生新的有效命令
A-CFG-005: Config Manager 只产生 WRITE
```

`cfg_record_count=0` 已定义：接受 `cfg_start` 后不派发任何 Driver 命令，直接产生 `cfg_done`，不等待 `cfg_bus_ready`。

---

## 7. Power Sequence Engine 验证

PSE 是当前最复杂业务模块，应重点覆盖 RAM 解析、参数装载、多 BUS 调度、Step、Delay、边界和 abort。

### 7.1 RAM / EN_MASK / Parameter

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| PSE-001 | EN_MASK=0 | 无有效通道 | 不产生通道参数写 |
| PSE-002 | CH0 only | bit0=1 | BUS0 DEV0 映射正确 |
| PSE-003 | CH127 only | bit127=1 | BUS7 DEV15 映射正确 |
| PSE-004 | 稀疏 mask | CH2/CH17 等 | Parameter 与置 1 bit 顺序一致 |
| PSE-005 | 全通道 | 128 bit 全 1 | 128 条通道参数完整覆盖 |
| PSE-006 | POWER_ON 参数 | seq_mode=ON | 使用 UP 三个参数 |
| PSE-007 | POWER_OFF 参数 | seq_mode=OFF | 使用 DOWN 三个参数 |
| PSE-008 | 参数寄存器顺序 | 单通道 | End/Step/Divider 顺序正确 |

### 7.2 参数装载与多 BUS 调度

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| PSE-009 | 同 BUS 多 DEV | 一个 BUS 多 bit | DEVICE_ID 顺序正确 |
| PSE-010 | 多 BUS ready | 多 BUS 同时有任务 | 可跨 BUS 连续派发 |
| PSE-011 | BUS0 busy | BUS0 not ready，BUS1 ready | BUS1 不被 BUS0 阻塞 |
| PSE-012 | 随机 backpressure | ready 随机变化 | 不丢、不重、不串通道 |
| PSE-013 | 参数全部提交 | 最后一批握手 | 不立即进入 Sequence |
| PSE-014 | 参数完成屏障 | 部分 Driver 尚 busy | 等 `seq_bus_ready=FF` |
| PSE-015 | mode 锁存 | 执行中改变输入 mode | 本轮仍使用启动时 mode |

### 7.3 EN Sequence

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| PSE-016 | change_mask=0 | target=current | 本 Step 不产生 Ramp Enable |
| PSE-017 | 单 bit 改变 | 1 个通道变化 | 仅该通道触发 |
| PSE-018 | mask 外变化 | target 改 EN_MASK 外 bit | 完全忽略 |
| PSE-019 | 全 128 改变 | 全通道变化 | 全部通道各触发一次 |
| PSE-020 | 固定 Enable 命令 | 任意改变 | REG/DATA 固定正确 |
| PSE-021 | pending 清除 | 某命令握手 | 只清对应 BUS/DEV bit |
| PSE-022 | Step 完成 | pending 全清 | 更新 current_state |
| PSE-023 | 同 BUS 顺序 | 单 BUS 多 pending | DEVICE_ID 顺序正确 |
| PSE-024 | 跨 BUS 非阻塞 | 某 BUS busy | 其他 ready BUS 继续派发 |

### 7.4 Delay / Step 边界 / abort

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| PSE-025 | Delay=0 | step delay=0 | 无额外等待进入下一步 |
| PSE-026 | Delay=1 | 最小非零 delay | 计时边界正确 |
| PSE-027 | Delay 最大值 | 16'hFFFF | 不溢出、周期正确 |
| PSE-028 | Delay 起点 | pending 最后一次握手 | 从全部握手完成后开始计时 |
| PSE-029 | UP_STEP_COUNT=1 | 单 step | 正常 done |
| PSE-030 | STEP_COUNT=32 | 最大预留步数 | 地址推进无越界 |
| PSE-031 | STEP_COUNT=0 | 空 sequence | 不装载 Ramp 参数、不触发 Ramp，直接 seq_done |
| PSE-032 | abort 参数阶段 | 参数派发中 | 取消未握手 valid、清 pending |
| PSE-033 | abort Sequence | Ramp pending 中 | 停止后续派发 |
| PSE-034 | abort Delay | delay 中 | 立即退出流程 |
| PSE-035 | abort 已握手事务 | 握手后 abort | 已交给 Driver 的事务不撤销 |
| PSE-036 | reset | 各状态 reset | 回 idle、pending 清零 |
| PSE-037 | busy 时重复 start | seq_busy=1 时再次 seq_start | 忽略，不重启、不重锁存 seq_mode |

### PSE 在线检查项

```text
A-PSE-001: 任何被派发 channel 必须满足 EN_MASK[channel]=1
A-PSE-002: pending bit 只能在对应 valid&&ready 后清除
A-PSE-003: 参数阶段完成前不得发 Ramp Enable
A-PSE-004: 参数阶段结束 -> seq_bus_ready 必须为 FF
A-PSE-005: Delay 期间不得派发下一 Step 命令
A-PSE-006: seq_abort 后不得产生新的有效命令
```

---

## 8. Alarm Handler 验证

Alarm Handler 重点验证“锁存 alarm_vector、逐器件 READ、等待 rsp_valid、结果 RAM、fault vector、独立 clear”。

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| ALM-001 | 单 BUS 报警 | vector 单 bit | 仅扫描该 BUS 16 Device |
| ALM-002 | 多 BUS 报警 | 多 bit | 每个置位 BUS 扫描 16 Device |
| ALM-003 | 未报警 BUS | vector bit=0 | 不访问对应 BUS |
| ALM-004 | alarm_vector 锁存 | 扫描中改变实时 ALARM | 本轮扫描范围不改变 |
| ALM-005 | READ 握手 | cmd ready | 握手后进入等待 response |
| ALM-006 | response 延迟 | rsp_valid 延迟随机 | 未返回前不能扫描下一 Device |
| ALM-007 | status=0 | 返回 0 | 不写 fault record |
| ALM-008 | status!=0 | 返回非 0 | 写 Record、count++、vector置位 |
| ALM-009 | 多故障 | 多 Device 非 0 | Record 顺序、count 正确 |
| ALM-010 | 128 全故障 | 全部非 0 | 最大 258 word 不越界 |
| ALM-011 | 新扫描 | 上轮已有结果 | count/vector 重置，旧 RAM 可残留 |
| ALM-012 | alarm_done | 最后 response 返回 | 完成时机正确 |
| ALM-013 | clear 单设备 | fault vector 单 bit | 只访问该 Device 0x44 |
| ALM-014 | clear 多设备 | 多 bit | 只清已记录 Device |
| ALM-015 | clear 等 rsp | 0x44 已握手 | 必须等 rsp_valid 才推进 |
| ALM-016 | clear done | 最后 clear rsp | 单周期完成脉冲 |
| ALM-017 | abort | 扫描中 alarm_abort | 停止后续访问 |
| ALM-018 | reset | 任意状态 reset | 回 idle |

### Alarm 在线检查项

```text
A-ALM-001: 每个 READ handshake 后，在 rsp_valid 前不得提交依赖该结果的下一 Device READ
A-ALM-002: status==0 不得增加 FAULT_COUNT
A-ALM-003: device_fault_vector 置位必须对应 status!=0
A-ALM-004: 扫描阶段不得访问 0x44
A-ALM-005: clear 阶段目标必须来自 device_fault_vector
A-ALM-006: 新 alarm_start 时 FAULT_COUNT 和 device_fault_vector 清零
```

---

## 9. System Controller 验证

重点验证状态切换、业务模块选择、Alarm 抢占、bus_fault 高优先级和 fault 锁存。

| ID | 场景 | 激励 | 主要检查点 |
|---|---|---|---|
| SYS-001 | Config 启动 | 上位机 cfg cmd | cfg_start 单脉冲，sel=CONFIG |
| SYS-002 | Config 完成 | cfg_done | 进入 READY |
| SYS-003 | Sequence 启动 | 上位机 seq cmd | seq_start 单脉冲，sel=SEQUENCE |
| SYS-004 | Sequence 完成 | seq_done | 返回目标正常状态 |
| SYS-005 | READY 中 Alarm | ALARM 有效 | 锁存 vector，启动 Alarm |
| SYS-006 | Sequence 中 Alarm | 执行中 ALARM | abort 当前 Sequence，切 Alarm |
| SYS-007 | Alarm 扫描完成 | alarm_done | 进入 FAULT_HANDLE，不恢复原流程 |
| SYS-008 | bus_fault | 任意正常状态 fault | 立即进入 FAULT |
| SYS-009 | fault 中止 Config | Config 中 fault | cfg_abort 发出 |
| SYS-010 | fault 中止 Sequence | Sequence 中 fault | seq_abort 发出 |
| SYS-011 | 多 BUS fault | 多 bit 同时 fault | 完整锁存 8-bit vector |
| SYS-012 | fault clear Driver | fault 锁存后 | 对应 driver clear pulse |
| SYS-013 | sticky 系统 fault | Driver fault 已清 | 系统 fault 仍保留 |
| SYS-014 | fault > alarm | 同周期同时出现 | fault 优先 |
| SYS-015 | alarm > normal | 正常业务与 alarm 同时 | alarm 优先 |
| SYS-016 | 系统 fault reset | FAULT 中 fault_reset | 等 Driver 全 ready 后清 fault，进入 IDLE，不恢复原流程 |

### System Controller 在线检查项

```text
A-SYS-001: FAULT 状态不得继续选择 Config/PSE 发新命令
A-SYS-002: fault_vector_latched 不得因 Driver fault clear 自动消失
A-SYS-003: bus_fault 与 ALARM 同时出现时最终必须进入 FAULT
A-SYS-004: 任意时刻只能有一个业务模块拥有公共命令通路
A-SYS-005: start/abort/clear 类控制信号均为规定脉冲宽度
```

---

## 10. 子系统集成验证

模块级通过后，再进行组合验证。集成测试不重复穷举模块内部细节，重点验证接口连接和跨模块行为。

| ID | 场景 | 主要检查点 |
|---|---|---|
| INT-001 | Config -> READY | 最后一笔 SPI/BUSY 真正结束后才 READY |
| INT-002 | Config 跨 BUS | BUS 路由正确，不同 BUS 可重叠 |
| INT-003 | PSE 参数装载 | 8 Driver 独立 backpressure 时仍正确完成 |
| INT-004 | PSE Sequence | 多 BUS Ramp Enable 无丢失/重复 |
| INT-005 | Sequence 中 Alarm | abort PSE，完成扫描后进入 FAULT_HANDLE，不恢复原 Sequence |
| INT-006 | Alarm 读回 | Driver rsp 正确送回 Alarm Handler |
| INT-007 | 任意阶段 BUSY timeout | Driver -> System fault 链路完整 |
| INT-008 | 多 BUS 同时 fault | 系统 vector 不丢 bit |
| INT-009 | Alarm + bus_fault 竞争 | bus_fault 优先级正确 |
| INT-010 | fault clear | Driver 恢复 ready，但系统仍处于 FAULT |
| INT-011 | reset | 所有模块、Driver、MUX 回一致初态 |
| INT-012 | Alarm 故障流程 | Config -> Power On -> Alarm -> Scan -> FAULT_HANDLE -> Clear |

---

## 11. 边界条件清单

以下条件不应只靠随机测试碰到，应至少有 directed testcase 明确覆盖：

- DEVICE_ID：0、15；
- BUS_ID：0、7；
- Channel：0、127；
- EN_MASK：全 0、单 bit、稀疏、多 BUS、全 1；
- Config Record Count：0、1、最大值；
- Sequence Step Count：0、1、32；
- Delay：0、1、最大值；
- Alarm fault count：0、1、128；
- ready：一直高、单次 stall、长时间 stall、随机 stall；
- rsp_valid：最短延迟、长延迟；
- abort：命令握手前、握手同周期、握手后、等待阶段；
- fault：单 BUS、多 BUS、与 ALARM 同周期；
- reset：IDLE、BUSY、WAIT_RSP、WAIT_DELAY、FAULT 等状态。


