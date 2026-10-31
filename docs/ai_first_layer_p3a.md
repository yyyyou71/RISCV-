# P3a：HDMI 张量接入真实模型第 1 层

根工程 rv32I.pds，顶层 acore_dual_top；ENABLE_AI=1、STANDALONE_CAPTURE=1、groute_seed=3。
这是 99 层模型的第 1 层集成检查点，不是完整 YOLO 推理，尚无检测框或 PCIe 画框输出。

## 当前数据流

HDMI RGB888 → 96×96 RGB INT16/HWC-align16 → DDR → W8A16 第 1 层 → DDR → CPU 比较 → SPI。
视频自检通过、原图和张量已持有后，CPU 自动执行一次真实模型第 1 层：
3×3、stride 2、padding 1、ReLU、3 输入/32 输出通道，完整输出 48×48×32。
CPU 将该层 5,760-byte 权重/偏置/量化常量装入 DDR，再提交已有硬件算子。
图像和特征图经硬件 DDR 通路处理，CPU 不逐像素搬运视频。

仅这一个小层参数暂存片上 RAM；完整约 10 MiB 权重仍待通过 SPI 加载到 DDR。
CPU 先读输入左上 2×2 像素，按实际权重、Q13 舍入/钳位/ReLU 计算首个输出像素。
硬件执行整层后，检查输出尺寸、1,327,104 次 MAC issue，逐通道比较首像素的 32 个输出。
首像素检查不是整张特征图比对，也不是全网检测结果验证。

权重装载、输入补丁读取、算子等待和输出读回均为协作式状态机，SPI 始终可查询。
单次 CPU DDR 窗口等待最多 250ms，首层算子等待最多 30s。
AI 运行时拒绝 video-release/retry，防止输入张量或原图租约被释放。
AI 完成/失败仍保留该帧，之后可由 RK 释放或重试。硬件 FAULT 仍需协调板级共同复位。

## 上板与终端

ROM/RAM 已重新生成为 firmware/video_diagnostic/ 的新固件。
重新打开根 PDS，从 Compile/综合开始完成实现、生成位流并烧录。
复制更新后的 csrc/rk_fspi 到 RK，在目录内执行：

```sh
make clean
make all
./rk_comm_cli /dev/spidev4.0
```

无需 IIC。终端会显示视频日志以及 [video]/[ai] 状态。
视频正常后应出现 first real model layer running，成功显示 PASSED_FIRST_PIXEL 和 checked_channels=32。
如果 HDMI 仍报尺寸错误，AI 保持 IDLE，不会使用无效张量运行。
停止监听后可执行：

```sh
./rk_comm_cli /dev/spidev4.0 ai-status
./rk_comm_cli /dev/spidev4.0 video-status
./rk_comm_cli /dev/spidev4.0 video-retry
```

AI 错误单独报告，不覆盖视频错误阶段。错误编号：1 输入地址/大小不符；2 未启用 W8A16；
3 DDR 窗口不可用；4 窗口超时；5 DDR 读写失败；6 RGB 超出 0..255；7 算子超时；
8 算子错误；9 输出尺寸/issue 不符；10 首像素通道失配。
ai-status 显示 frame ID、硬件状态/周期、已加载字节、输出尺寸、失配通道和期望/实际值。

## DDR 和 IP

| 用途 | AI 逻辑字节地址 | 物理字节地址 | 大小 |
| --- | --- | --- | --- |
| 输出 | 0x03c00000 | 0x07c00000 | 147,456 bytes |
| 权重、偏置、量化 | 0x03d00000 | 0x07d00000 | 5,760 bytes |
| 保留的预处理输入 | 0x03f00000 | 0x07f00000 | 294,912 bytes |

沿用现有 AI 用户口地址平移和整突发仲裁，只使用一套物理 DDR3 controller/PHY，
不改变原图帧槽布局。这些首层诊断区域须避免与后续模型加载器冲突。
已有 pango_ai_multadd.idf 已生成并注册到根 PDS：signed 16×8 两项乘加、25-bit 输出、
同步复位、3 个 CE 流水级、固定加法。固定模式生成器没有 addsub 端口，
因此修正了 RTL 边界的无效端口连接；上游 addsub 恒 0，运算不变。
未生成旧 W8A8 IP，未引入第二套 CPU 或 Cache。

## 已做检查与边界

- 根 PDS Compile 通过；本次不运行综合/P&R/位流生成，由用户执行。
- 新厂商 GTP_APM_E2 短检查：延迟、有符号极值、CE 暂停与复位，101 次比较。
- CPU 首像素检查器与原 TridentVision C 对比：16 个小输入补丁、512 个通道。
- 固件和 RK 工具编译通过，RK 主机 mock 覆盖 ai-status。
- 没有重跑全 AI 引擎或全网长仿真；没有板级验收，不能用旧资源/时序代表启用 AI 后的结果。

复现资产/软件检查：

```sh
python3 scripts/export_first_layer.py --model build/integration-review/model_prepared/model.bin
python3 scripts/check_first_layer_reference.py --reference /mnt/c/Users/yyyyou71/Desktop/TridentVision
python3 scripts/build_firmware.py --application video_diagnostic --core acore_dual --image-dir firmware/video_diagnostic
```

Windows 的 scripts/check_ai_vendor_multadd.py 只检查新厂商乘加边界。
记录见 reports/preprocess/first_layer_*.json。
资源看 synthesize/acore_dual_top.snr 和 place_route/acore_dual_top.prr；
最终时序看 place_route/acore_dual_top.rtr，以本次实现时间为准。

建议提交：feat: 接入W8A16真实模型首层与SPI诊断自检。
下一阶段：SPI 完整模型分块装载、99 任务调度、六头 CPU 后处理，再接画框和 PCIe 输出。
