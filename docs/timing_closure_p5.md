# AI、SPI 与复位时序修复（P5 前置检查点）

基线为 `c39d798`。唯一维护入口仍为根目录 `rv32I.pds`，自己的 Acore 顺序双发射，
CPU 25 MHz、DDR 用户口 131.25 MHz、HDMI 像素 148.5 MHz、SPI 50 MHz Mode 3，布线种子 3。
本检查点不代表连续多帧、整网板测或 HDMI 输入故障已经完成验收。

## 配置接收与校验

`conv2d_ddr_engine` 在命令握手时锁存完整配置。CPU 原有请求翻转同步、忙时冻结配置和完成确认不变。
DDR 域依次计算通道间距、输出形状、区域大小、区域末端，最后执行原有参数和区域重叠检查。
新增 `ai_config_sizes` 复用一个 64×32 位串行乘法器计算配置所需乘积，不把宽乘法串联在一个周期内。
保留原来的无符号 64 位截断语义，非法大尺寸也不能通过截断成小地址而绕过原检查。

非法命令现在需要等待校验完成才返回错误；校验期间 BUSY 为 1，不发起 DDR 请求。
每个任务仅执行一次配置计算，增加约几微秒启动延迟，不改变算子数值、布局、MMIO 地址和错误码。
第一步独立综合中，CPU→DDR 配置方向 setup 从 -10.942 ns 改为 +4.844 ns。
该中间报告不是最终布局布线结论。

## 地址生成

`ai_mul32_pipeline` 使用四个注册的 16×16 部分积和分级求和生成精确的 32×32 无符号乘积。
`ai_address_math` 依次执行像素/权重索引乘法、通道间距乘法、通道偏移、字节缩放和基址相加。
地址保持到 DDR 请求被接受，反压不会重复提交。无效输出通道和边界补零继续走原路径。

没有修改 W8A16 MAC、Q13 舍入、饱和、ReLU 或组间量化规则。
这一步增加每次卷积访存地址生成的等待周期：短检查的两个卷积样例分别从 6436/10029 周期
变为 8990/15432 周期，MAC issue 和 DDR 请求次数不变。这些是小输入随机等待仿真，
不能当成整网实板耗时或 FPS。后续可以用行基址预计算和地址递增减少等待。

## SPI 输出

在活动顶层增加 SPI 全局时钟缓冲。数据和四个独立的高有效三态控制寄存器申请 I/O register packing，
使用 PDS 文档支持的 `syn_useioff`，输出使能寄存器保留，直接连接各个 pad 的三态控制。
去除使能寄存器之后重复的 CS/复位组合门；CS 和全局复位仍异步关闭输出，SCK 停止时也释放总线。
没有改变收发协议、方向、边沿、包大小或 RK 工具。
本次 Device Map 确认四个发送数据寄存器打包进 OFF；输出使能的 I/O packing 属性有忽略提示，
所以不能把申请属性当作所有寄存器已进入 I/O 资源的证明，仍需看实际路径。

## ADD 后续关键路径

地址分拍后，统一综合的 DDR 域最差 setup 改为 -1.663 ns，关键路径转到
`add_int16` 的舍入偏置、64 位加法、可变移位、双路求和和饱和选择。
继续把这些操作分成 ROUND/ADJUST/SHIFT/SUM/SATURATE 阶段，保留有符号 64 位中间值、
RHU 舍入和 [-32767,32767] 饱和范围；无效参数仍返回错误和零结果。
输出在反压时保持，输入在握手后锁存。256 组数值/握手检查及原 C ADD 小样例通过。

## 视频写端复位

`ddr3_write_ctrl_lite` 分别在像素域与 DDR 域同步释放复位，异步拉低保持。
通过新增输出 `pixel_reset_n` 将像素域释放信号同时送到 `hdmi_in_detector`，
保证标记生成器、SOF 计数和 FIFO 写端在同一像素周期开始运行。
FIFO 写复位和读复位分别使用所在域的释放信号。
`video_timing_monitor` 的像素侧计数器也改用本像素域同步释放，CPU 侧测量结果接口不变。

约束只豁免原 CPU 域复位到两组复位同步链的异步输入；同步级之间、复位末级到本域消费者仍计时。
没有扩大 CPU/DDR 邮箱的传播预算，没有关闭 hold 修复，没有调整参考 DDR PHY 参数。

## 验证范围和报告

- `TB_ai_config_sizes`：128 组 W8/W16 宽位乘积、溢出和处理中复位。
- `TB_ai_address_pipeline`：256 组完整位宽地址、输入快照、反压、消费与取消。
- `TB_add_pipeline`：256 组有符号输入、0..63 位移位、饱和、非法参数、快照和输出反压。
- 五种算子各选两个小输入，与原 TridentVision C 参考逐字比较；保留非法命令、超时和复位恢复检查。
- `TB_ai_control`：MMIO 配置冻结、故障传播、处理中复位和恢复。
- `TB_fspi`：50 MHz Mode 3，1/16/256/2048 字节、短包重试、所有权、溢出和停止 SCK 时复位。
- `TB_frame_protection`：帧号、帧槽保留、全保护丢帧和恢复、并发 CPU 持有。
- `TB_video_timing`：正确 1080p、实测周期、错误行/帧拒绝、恢复与复位。

未跑 CoreMark 或整网长仿真。没有将这些短检查描述为 HDMI、RK 或完整模型板测通过。
算子检查可在 WSL 执行：

```sh
python3 scripts/check_ai_timing.py --reference /mnt/c/Users/yyyyou71/Desktop/TridentVision --stage final
```

算子记录：`reports/video_integration/timing_stage2_checks.json`。
最终构建审计：`reports/video_integration/timing_closure_p5.json`（构建结束后生成）。
本轮短检查汇总：`reports/video_integration/timing_unit_checks.json`。
中间工具日志和报告副本保存在忽略目录 `build/timing-closure/`。

PDS 默认输出：

- 综合资源/估算时序：`synthesize/acore_dual_top.snr`。
- 最终资源：`place_route/acore_dual_top.prr`。
- 最终时序：`place_route/acore_dual_top.rtr`。
- 单独 Report Timing 的复核报告：`report_timing/acore_dual_top.rtr`。
- 位流：`generate_bitstream/acore_dual_top.sbit`。

只有本轮最新源码对应的最终布局布线与位流才能作为交付依据；旧文件和中间 hold 快照不能替代最终报告。

## 本轮最终实现结果

新一轮 P&R 与独立 Report Timing 已执行，二者结论一致：**尚未完全收敛**。
CPU→DDR 配置 setup 为 +6.479 ns；50 MHz SPI setup 为 +0.248 ns；像素域复位检查通过。
剩余 slow setup：DDR 域 -0.855 ns（245 个端点），PCIe pclk_div2 -0.278 ns（1 个端点）；
fast hold：CPU 域 -0.001 ns（1 个端点）。不能将这一检查点称为时序通过版本。
完整 batch 已生成新位流（2026-11-01 16:41），本次最后一轮从 Compile 到位流耗时 56 分 49 秒。
文件仍为 `generate_bitstream/acore_dual_top.sbit`，SHA256 为
`fbc9dbe9707dad5421d1aefe3d10b468922111b0b2692f7a6cc0104a1a007d40`。
位流生成成功与时序通过分别记录；审计报告的 `passed=false` 是剩余违例导致的，不是缺少新产物。

DDR 当前最差路径为 MAC tile 的 `valid_words[8]` 到累加器 `sums` 的 CE；
另外有配置校验到状态控制、坐标判断到缓存装载控制的路径，下一检查点应优先截断这些控制链。
PCIe 剩余路径在参考 DMA 的 BAR2 RAM 到 MWr 读 FIFO 中；CPU 小 hold 位于画框配置寄存器反馈路径。
没有通过改时钟周期或 false path 隐藏这些违例。

最终资源（PDS PRR 模块统计）：

| 资源 | 使用 / 容量 | 比例 |
|---|---:|---:|
| LUT | 39,625 / 66,600 | 59.50% |
| FF | 34,978 / 133,200 | 26.26% |
| APM | 21 / 240 | 8.75% |
| DRM36K 等效块 | 87.5 / 155 | 56.45% |

PDS 报告记录 placement 411.83 秒、global routing 44.08 秒、detailed routing 810.86 秒，
路由器内 hold 修复 95.77 秒，额外 hold 修复 146.73 秒；额外修复未能消除上述 1 ps fast hold。
这些分项不是完整 batch 的墙钟时间；本轮还执行了多次综合和报告生成。
CLI 后续可跳过无需每次运行的功耗与导出网表步骤：

```powershell
& '<PDS安装目录>/bin/pds_shell.exe' -project rv32I.pds -run gen_bit_stream -skip_actions 'report_power gen_netlist'
```
