# 板级预处理与 AI 完整功能仿真

入口为 `scripts/check_board_ai_full.py --preprocess`，在 WSL 中运行。
它使用根工程的 `acore_dual_top`，不把原图完成或张量完成信号人为置为成功。

## 实际连接

测试台提供 1080p 的 RGB888 / DE / VS / HS 流，每行有效输入 1919 个像素，
行周期 2200 像素时钟、帧周期 1125 行。RGB 为确定性彩色图案。
工程中的 `hdmi_line_pad` 补最后一个黑色像素，然后：

* 原图经过实际整形/帧标记、厂商 FIFO、共享仲裁写到 DDR 原图帧槽。
* `rgb888_pool96` 实际缩到 96×96；生成 HWC、16 通道对齐的 INT16 张量，
  经实际厂商 FIFO 和 DDR 写入 0x03f00000 逻辑地址。
* 软核通过现有 MMIO 发起抓帧，等待实际原图完成、同帧租约和张量写入完成。
* 测试台逐字比较硬件写出的 18432 个张量字；软核再通过真实 DDR 窗口回读核对。
  该模式禁止软核将参考张量写入输入区，不能用软件替换硬件预处理来通过测试。
* 双发射 Acore 调用生产 `ai_run_model_input`，执行实际 99 个 RTL 任务和生产后处理。
  检查输入地址确实重绑定到高地址，禁止引擎回读模型包中的原始输入。
* 最后比较全部中间张量、检测头、只读资产、边界哨兵和 CPU 检测结果。

板上 CPU 逻辑 DDR 地址增加 0x04000000 的物理字节偏移，使用实际共享仲裁和范围检查。
预处理、原图和 AI 的访问均经过同一个原生 DDR 行为模型，并启用随机等待。

## 独立参考

Python 按 20 列 × 12 行的窗口计算预处理期望值，纵向起点 floor(y×1080/96)，
不足 1920 的行尾当黑色，除以 240 后按最近偶数舍入。没有调用被测 RTL 来生成期望值。
该输入交给桌面 TridentVision 的定点 C 参考，生成全部 99 个任务输出，并与其原始
`forward_fixed` 对比；CPU 后处理另与独立参考核对分数、顺序及坐标。

## 仿真边界

使用实际生成的 `pango_ai_multadd`、`fifo_2_ddr`、`pango_pool_sum_ram` 和紫光
`GTP_APM_E2` / `GTP_DRM36K_E1` 原语仿真模型。
DDR 物理 PHY、HDMI 接收芯片、PCIe 物理链路不在验证范围。
CPU ROM/RAM 和 CPU 乘法的存储/延迟模型仍采用工程已有仿真替代。
测试台以理想时钟和同步输入驱动 HDMI 接口；通过不能证明实板接收时序已经正确。
本例比较 AI 输入张量的每个字，原图通路验证完整帧与同帧租约，尚不逐像素比较 RGB565 原图。
当前未启动 PCIe 图像回传，不能用本例证明 RK 显示或画框链路完成。

## 运行

在 WSL 的工程目录执行，避免并发使用同一个输出目录：

```sh
python3 scripts/check_board_ai_full.py \
  --reference /mnt/c/Users/yyyyou71/Desktop/TridentVision \
  --pds-root /mnt/c/diskE/FPGA_Learning/PGenvironment/PDS_2022.2-SP6.1 \
  --out build/ai-full-preprocess --jobs 4 --preprocess
```

C 参考、输入及逐任务仿真日志位于：
`build/ai-full-preprocess/model/segments/000_099_board/`。
只有全部通过后才会生成 `reports/ai_port/full_board_network.json`；
目录存在、参考生成完成或单个任务 error=0 都不能代替整网通过。

早期 `build/ai-full-board` 中只含 DDR 张量搬运的长仿真已因本次扩大范围而停止，
它没有通过报告，不作为当前包含预处理链路的验证依据。
这些文件均为测试入口，不加入 PDS，不改变 FPGA 的视频传输格式。

## 本次结果

2026-11-03，包含硬件预处理的完整运行通过。全部 99 个任务完成且无硬件错误，
最终比较 850773 个 DDR 字（含中间张量、检测头、资产与哨兵）一致；
硬件预处理输出的 18432 个张量字和软核回读均一致。
引擎从绑定输入区实际发起 163592 个读突发，未回退使用模型包中的原始输入。
CPU 后处理实际写回 2 条检测记录，与参考一致。
仿真运行约 1634 秒，不含编译；该耗时不是 FPGA 实际推理耗时。

报告：`reports/ai_port/full_board_network.json`。
本次未修改产品 RTL 来通过仿真，实板抓帧数量不足仍需独立定位。
