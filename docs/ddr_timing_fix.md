# DDR 域时序修复：帧槽选择与保护

基线：`428920d`。本次优先修复根工程，不改变参考 DDR IP、PHY、初始化参数、视频原生地址布局或 PCIe DMA。
用户原有 DDR 行为仿真和参考工程继续作为基础；新增验证集中在集成逻辑。

## 最终验证结果（2026-10-30）

根工程 `rv32I.pds` 保持 `gplace_seed=2`，将 `groute_seed` 从 2 改为 3。
核对活动硬件源码与已综合快照的 SHA256 全部一致后，复用此前种子 3 的布线数据库，
将其对齐到根工程的 `place_route/`，重新执行最终 STA。未修改 DDR RTL、PHY 参数或时序要求。

- 最终 `place_route/acore_dual_top.rtr` 于 16:38:22 生成，结果为 `All Constraints Met`。
- 原 DDR PHY 路径 setup 从 -0.009 ns 改为 +0.253 ns；全设计最差 setup 为 +0.253 ns，hold 为 +0.018 ns。
- 对应位流 `generate_bitstream/acore_dual_top.sbit` 于 16:39:04 生成；用户随后接手自行生成和烧录。
- 审计结果为 `reports/video_integration/ddr_timing_fix.json`；旧产物保存在忽略目录
  `build/video-platform/before_seed3_adoption/`，工具日志在 `build/video-platform/seed3/`。
- 本轮只重做最终时序检查和对应位流生成，没有新增功能仿真。尚未完成板级验收。

PDS 若仍打开旧工程窗口，应重新打开根工程，以免旧设置将布线种子回写为 2。
后续改动仍需检查最终 `.rtr`；`*_timing_summary_after_hold_fix.txt` 是中间快照，不能单独作为通过依据。

## 原因

1. 原先的同步器例外使用 RTL 名称加 `/D`，在 PDS 综合导入阶段找不到这些 pin，综合中止。
2. 改为 PDS 支持的 `get_cells -hierarchical` 寄存器终点后，根工程综合完成。
3. 实际综合报告暴露 DDR 131.25 MHz 域的 -2.137 ns 余量：
   `u_write_ctrl.frame_ids[0] → frame_mailbox 的串联帧号比较 → provisional hold_mask → 写槽选择 → axi_awaddr`。

这条路径来自新加的帧管理逻辑，不是 DDR IP 原生读写延迟或带宽不足。

## RTL 改动

`rtl/frame_mailbox.v` 将一次串联比较五个 32-bit 帧号，改为每周期比较一个候选槽。
接到请求时保存可选槽位快照，排除当前写槽；随后用五周期选择最新帧，返回同样的 CPU BUSY/DONE/HELD 接口。
帧号仍用模 2^32 的有符号差比较，已有 lease 的重复获取不更换帧。

选择期间的保护不再依赖帧号比较结果：

- 请求抵达的第一拍先保护当前 available，关闭与新 SOF 同拍争用的窗口。
- 扫描时保留快照 reserved；即使 PCIe 读端清除了 available，也不释放尚在选择中的槽。
- 最后一拍从快照保护直接切换到最终 core_held 保护，没有空拍。
- DDR 未就绪、共享故障和共同复位仍会结束/清除相关事务。

没有仅仅延迟 hold_mask 而不保留槽位，也没有通过降低 DDR 时钟或扩大 false path 来掩盖长路径。

## 约束与验证

`board/timing.fdc` 使用实际匹配的寄存器 cell 作为异步首级终点；逐条匹配结果须保存在实现记录中。
PDS 在综合前将 IIC 的两级移位寄存器视为一个 vector cell，因此该例外同时限定
`-from [get_ports {iic_scl iic_sda}]`；第一级 Q 到第二级 D 的寄存器路径不属于外部 port 起点，仍需计时。
CPU/DDR 稳定邮箱的传播上限保留，但改用 `set_max_delay -datapath_only`，
并仅对列出的跨域方向设置 `set_false_path -hold`。普通 `set_min_delay 0` 会按同边沿时钟插入延迟
制造跨域 hold 条件：实测报告中 sys_clk→ddrphy_sysclk 的 2,185 个邮箱端点出现约 -6 ns 假违例。
握手邮箱不在发起变化的同一边沿采样，不能以延迟数据总线若干 ns 代替它的协议约束。
所有 DDR 域内部、CPU 域内部的 setup/hold 仍完整保留；跨域数据仍受 15/40/6.5 ns 传播预算约束。

新增 `ddr_region_check.v` 将 CPU 原生请求的范围检查寄存后交给仲裁器，
去掉 segment_beats→范围加法/比较→DDR READY→错误状态的单周期长链。
请求在反压期间保持稳定，接受后清除资格，下一个请求必须重新检查；越界请求仍不能进入物理 DDR。
新增测试覆盖所有 1..16 拍突发在区间上边界的允许/拒绝，以及连续 VALID、反压和复位。

`acore_dual_top` 给新增 CPU 域显式使用 `GTP_CLKBUFG`，根部 ready/fault 同步器也使用此时钟。
新增视频监测模块也接同一全局缓冲时钟，避免 raw sys_clk 经 SRB 普通布线再与 CPU 全局时钟交换数据。
DDR IP 和参考 PLL 仍接原始 25 MHz 引脚，不改其 PLL/PHY 参数。

重新逐条核对参考 `fdc/pcie_dma_test.fdc`，补回此前导入时遗漏的两条 DDR PHY 多周期约束、
四条双向时钟不确定度约束。桌面参考工程 `report_timing/pcie_dma_test.rtr` 的这两组 PHY 路径
setup/hold 均通过；因此先保留其完整约束，不根据卡在 84% 的现象直接更改 PHY 时序关系。

2026-10-30 的诊断确认：详细布线已完成，84% 对应后续 hold 修复，而非 routing 尚未完成。
旧日志一轮修复耗时 1,030 秒，随后继续迭代。诊断构建仅为导出修复前路径而暂不执行 hold 优化；
最终交付必须重新启用根工程的 hold 修复并检查新报告，不能将诊断构建作为验收通过。

已运行的短测试包括：

- 双发射 CPU 固件与视频同时访问 DDR，正常及随机等待下逐拍读回正确。
- mailbox 原有空帧、活动写槽排除、帧号回绕、重复获取、故障和复位检查。
- 扫描中 available 被读端清零，快照仍受保护，最终返回正确槽与帧号。
- 真实视频写控制器与 mailbox 并发：选帧、环绕写入、保留帧号、释放均检查，禁止向受保护槽发 AW。

功能结果在 `reports/video_integration/functional.json`；工具详细日志在 `build/video-platform/pds_console.log`。
最后必须以本次布局布线后的 `.prr`、`.rtr` 和新 `.sbit` 为准；综合通过不代表布线时序已经通过。

## 与预处理工作的边界

`rtl/video/preprocess/` 当前仅完成独立核验证，尚未接入活动顶层和 AI 模型。
其文件保留在工作区，本次 DDR 修复不将它描述成已经接入或已经产生推理结果。
