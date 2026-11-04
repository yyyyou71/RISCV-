# RK 交互浏览与 FPGA 地址流水优化（2026-11-04）

RK 增加 `--interactive`。图片按文件名字典顺序排列，首图自动处理并保持显示；终端输入 n/next、p/prev、q/quit 后回车。
前后切换首尾循环，运行中的命令在本帧推理、回图和释放完成后生效。模型只在启动时上传一次。
原有 RAW、AI、批处理、--loop、--frames、--save 保留，--interactive 与 --loop 互斥。
输出模式切换前先处理模型装载，避免上次上传中断留下 LOADING 状态时卡在 BUSY。

```sh
make all
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images --output ai --model ./face_model.bin --interactive
```

桌面交付包 `rk_face_browser_20261104.zip` 包含 RK 源码、face_model.bin 和 images/face.jpg，不含 WSL 的 x86 可执行文件。
在 RK 解压进入 rk_face_browser 目录，执行 `sh run_face_browser.sh`，会先在 RK 本机编译再启动。
更多照片放入 images/；已经在 FPGA 中的模型可以用 --use-loaded-model 复用，复位后重新上传。

## FPGA 局部流水线

地址公式保持 `((((a*b)+index_add)*pitch+inner)<<element_shift)+base`，模 2^32。
ai_address_math 只计算需要的低 32 位，将两次通用乘积从四级改为两级；b=1 直接使用 a。
通道间距为 1..2048 范围内的 2 的幂时用寄存后的移位路径，其余间距保留通用乘法。
输入快照、结果反压、取消、溢出截断、算子数值和量化规则保持一致。
conv2d_ddr_engine 在区域末端计算后增加 CFG_VALIDATE，寄存范围与重叠判断，再进入配置分发。
每条任务增加一拍校验，打断原 quant_end 比较到大量寄存器 CE 的组合长路径。
CPU 核、CPU/DDR/SPI 时钟及约束没有修改。

## 验证

- RK 全部主机测试通过，新增 next/prev/quit、处理中排队切图/退出、同帧 DMA、释放顺序及中断加载恢复检查。
- WSL/Icarus：五类算子逐字对照 C 黄金结果，包含非法参数、随机等待、共同复位和故障恢复。
- PDS + ModelSim：地址模块 512 组全位宽/2 的幂间距、输入快照、溢出、反压与取消通过，零错误零警告。
- PDS + ModelSim：DDR CPU 窗口 18 场景、19 个独立原生读通过；整板综合映射仍为 2048 个载荷触发器，无影子 RAM。
- 两个卷积小样例：8990→7959、15432→13228 周期，分别减少 11.47%、14.28%，MAC issue 数与 DDR 事务数量保持一致。
  这不代表整网实板速度。没有重跑训练或模型数学验证。

原始证据在 build/interactive-accel/，算子检查在 reports/video_integration/timing_interactive-final-staged_checks.json。
短检查汇总在 reports/video_integration/interactive_accel_checks.json。

## 实现状态与 CPU 验收

根工程完整 Compile→Synthesize→P&R→STA→Bitstream 流程已于 2026-11-04 01:52:57 完成，耗时约 42 分 15 秒，新位流已生成。
运行日志 build/interactive-accel/board-run/flow.log；状态 state.json；综合前硬件快照 source_hashes.json。
最终布线 CPU 最差 setup +9.733 ns、hold +0.029 ns，slow/fast 的 setup、hold、recovery、removal、最小脉宽均零违例。
DDR/AI 同域 setup -1.152 ns（78 个端点，TNS -19.030 ns）；DDR 到 PHY setup -0.891 ns（2 个端点）。全设计 hold 均通过，整体时序仍未通过，delivery_ready=false。
前版同域 setup -0.728 ns（253 个端点，TNS -42.838 ns），本次端点数量和 TNS 降低，但该域 WNS 变差。PHY setup 从 -2.838 ns 改善到 -0.891 ns，原 PHY hold 违例已消除。
当前最差 AI 路径是 ci_base 到 u_tile 权重缓存 DRM 输入，布线占 87.776%；PHY 最差路径布线占 88.986%。源码快照核验一致，CPU 缓冲仍为 2048 个触发器、无影子 RAM。
原实现数据库、网表和时序报告在 build/interactive-accel/baseline/ 备份。
原根目录 acore_dual_top.sbit 在本轮开始前不存在，不能把其他顶层的 board_top.sbit 当作本版位流。

构建结束后已自动运行 scripts/audit_interactive_accel.py，当前结果位于
reports/video_integration/interactive_accel_implementation.json。
CPU 内部 setup/hold 在 slow/fast 两角及报告内 recovery/removal 等全部检查，任何负余量都不通过。
其余时钟违例如实列出；setup < -0.5 ns 或 hold < -0.1 ns 单独标记需继续处理，这只是保守审查边界，并未放宽约束。
只有新位流、源码快照、CPU 最终时序、CPU 缓冲映射和其余严重违例检查均满足时，delivery_ready 才为 true。
最终上板速度及图片交互仍需 RK/FPGA 实板运行确认。
