# RK3568_MES2L100H：CACHE3 板级接口

本目录继承 BP1 板级封装，board_top 透传 I/D Cache、突发后端及等待参数。引脚、时钟、电平和复位保持不变。发布文件及各自 PDS 审计见 [主说明](../../README.md)，本版本仍待实物验收。下表描述 CoreMark 的 LED 含义；缓存/异常中断自检版的 LED0 每 250 ms 翻转，LED1 表示自检通过。

| 端口 | FPGA 球位 | IO 标准 | 本版作用 |
|---|---|---|---|
| sys_clk | V4 | LVCMOS15 | 板载 25 MHz，BANKR5 |
| key0_n | M15 | LVCMOS18 | 硬件复位，BANKL4 |
| key1_n | M16 | LVCMOS18 | 保留硬件接口，CoreMark 应用不使用 |
| led0 | J16 | LVCMOS18 | LED3，算法计时期间亮 |
| led1 | M17 | LVCMOS18 | LED4，该组 CRC 与时长都合格后亮 |
| uart_tx | AB21 | LVCMOS33 | FPGA 扩展口第 3 脚，软核发送 |
| uart_rx | AB22 | LVCMOS33 | FPGA 扩展口第 5 脚，软核接收 |

沿用此前成功接线：USB-TTL RX 接 FPGA TX，USB-TTL TX 接 FPGA RX，共地，串口 115200 8N1。板载 CH340C 调试串口连接 RK3568；本软核使用上述扩展 IO。

`pins.json` 定义球位，`electrical_review.json` 保留原包确认记录。主工程 `baseline.json` 进一步记录用户已上板成功的反馈与原包哈希。`scripts/prepare_board.py` 据此生成 FDC；本次沿用 L4=1.8V、R5=1.5V、UART 所在 L5=3.3V，不推断新的硬件电压。

`timing.fdc` 定义 40 ns 时钟及 0.2 ns 不确定度。异步按键/串口到同步器首级，以及寄存器到异步 UART/LED 输出端口设置例外；CPU、存储器及其余内部同步路径继续检查时序。PDS 报告中有关异步 IO 未设置同步延时的提示需结合这些例外理解。

复位和按键消抖仍为 10 ms。GPIO[7] 是板内的软件复位请求，不占用扩展管脚。ROM/RAM 各 32 KiB，各映射为 8 个 DRM36K；启用 Cache 时，数据银行映射为分布式 RAM。每份发布文件都独立检查资源、8192 字 ROM 初始化、复位初值和快慢角时序，数值以对应 reports/pds/<配置>/audit.json 为准。

`scripts/run_board_stage.ps1 -Implement` 是当前完整验证/实现入口。上板采集用 `run_board_coremark.ps1 -Variant burst|word|uncached`；旧 BP1 的实验仍使用其独立工程和位流。
