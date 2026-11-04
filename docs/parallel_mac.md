# 不改模型格式的卷积并行扩展

2026-11-04，在交互浏览/地址流水优化版之上增加：

- conv_mac_tile 新参数 REDUCE_PAIRS=1/2，默认保持旧两项乘积；板端 W8A16 引擎选择 2，每输出通道处理四项乘积。
- 输出通道仍为 4，单个输入块仍为 16 通道；权重、任务、DDR 排列、分组尺度和 Q13 量化规则保持不变。
- 复用两组现有真实 16x8 双乘加 IP，先符号扩展到 26 位再求和，独立寄存后进入 64 位累加。
  新增求和级与有效位、尾标志同步推进，compute_enable=0 时整条流水保持。
- 每个 tap 的计算发射由 8 次变为 4 次；peak products/issue 从 8 提升至 16，不能视为整网速度翻倍。
- engine→tile 增加一个弹性供数寄存级，数据和 weight/lane/tap 标签一起锁存；最后一个待写缓存数据排空后才启动计算。
- AISSUES/mac_issues 继续以原来的两项乘积工作量为单位，新物理发射累加 2，保持原模型/固件/统计 ABI 兼容。

face_model.bin、board_model.bin、RK 程序和 CPU 固件不需要为这一版重新导出或修改。需要下载新 FPGA 位流才能启用新并行硬件。

## 验证与收益

WSL/Icarus：12 个卷积样例全部逐字通过 C 黄金比较，覆盖尾通道、不同尺寸、1x1/3x3、两组量化、非法参数、随机等待、复位及 DDR 故障。
ADD/Concat/MaxPool/Upsample 原定向检查均通过。
PDS/ModelSim：使用真实生成乘加 IP 综合的 MAC 网表通过 16 场景，覆盖 1/9 taps、正负极值、随机数据、非零初值、随机使能暂停及输出反压。
网表仿真零错误；厂商 DRM 模型有 23 条模板警告（22 条初始化索引、1 条未使用函数返回值），没有屏蔽，原始日志保留。

相对上一版相同 12 个小卷积和相同随机 DDR 激励：总周期减少 3.80%，单例约 -0.09%～7.44%。
前两个例子 7959→7557、13228→12578，分别减少 5.05%、4.91%。
一个极小样例因新增寄存/随机等待多 1 周期。整网实际加速未上板测量。
这些结果表明继续单纯堆乘法器的收益受 DDR/控制开销限制，后续更应着眼于供数重叠与复用。

证据：reports/video_integration/parallel_mac_checks.json、build/parallel-mac/performance.json。
复现 MAC 网表：python scripts/check_parallel_mac_gate.py --out build/parallel-mac-gate-new
WSL 全部卷积样例：python3 scripts/check_ai_timing.py --reference /path/to/TridentVision --stage parallel-all --operators 2 --max-layers 0

## 实现

新一轮 PDS 综合已完成，布局完成并进入布线后按用户要求停止；不再启动实现。日志 build/parallel-mac/board-run/flow.log，状态 state.json。
上一版 RTL、综合网表、布局布线数据库、最终报告及位流完整备份于 build/parallel-mac/baseline/。
构建结束后自动写入 reports/video_integration/parallel_mac_implementation.json，CPU 任意内部违例仍不通过。
本轮尚未获得新的最终时序报告，不将并行扩展或供数寄存级宣称为时序收敛。

## 本次停止时的缓存候选

2KiB 精确请求读缓存位于 build/ddr-cache-candidate/rtl/，未加入根 PDS。
14 个缓存定向场景的 RTL/PDS 功能网表，以及五类算子的全部有效样例/非法参数/反压/复位/故障检查均通过。
同一组 12 个卷积样例：并行版 159437 周期，缓存候选 153135 周期，进一步减少 3.95%；DDR AR 从 4560 降至 3980，减少 12.72%。
缓存相对地址流水版的 12 样例总周期减少 7.61%；不存在未优化原版的同一组 12 样例基线，不能把它当作原版整网收益。
最后完整实现且 CPU 零违例的地址流水版位流在 build/parallel-mac/baseline/generate_bitstream/acore_dual_top.sbit。
新并行版与缓存候选尚无完成最终时序验收的位流，根目录 acore_dual_top.sbit 因被中断的构建已不存在。
