# HDMI 每行 1919 像素适配

本轮按实板确认的输入处理：1080 行，每行 1919 或 1920 个有效像素。
视频参考改用桌面 `purple-light-fpga-main/purple-light-fpga-main`；其 PDS 实际选用
`source/source/hdmi/` 和 `hdl/new_ring/hdmi_in_detector.v`。
本工程 HDMI 配置和 marker 前端的控制逻辑与这些源码相同，差异比较记录见
`reports/video_integration/hdmi_padding_reference.json`。

原有 `hdmi_in_detector` 本来就能补黑，但 `input_shape_ok` 在它之前拒绝了 1919 输入；
CPU 自检也只接受精确的 1920，AI 的 `rgb888_pool96` 则会拒绝任何不满 1920 的行。

现在 `board/acore_video_platform.v` 中先经过公共的 `hdmi_line_pad`，再分成两路：

```text
HDMI VS/DE/RGB888
  ├─ 原始尺寸监测 → SPI video-status（仍可显示 1919×1080）
  └─ 公共行补齐：1919 个真实像素 + 1 个黑像素 → 1920
       ├─ RGB565 → 原参考 marker/FIFO/DDR 帧缓冲 → PCIe
       └─ RGB888 → 原 96×96 预处理 → 张量 DDR → AI
```

公共前端将 VS、DE、RGB 同拍寄存，保留首个真实像素，在水平消隐中补足行尾。
1920 输入不增加黑列；短行在消隐时间允许时补到 1920，更长的行截断。
2026-11-02 按实板调试需要，原始宽高监测改为纯诊断，删除 `input_shape_ok`、
监测器的 shape_ok 资格输出和 CPU 起采前宽高等待。原图 stream_ok 固定为 1，
张量 source_ready 直接使用帧缓冲就绪信号，均不再附加尺寸条件。
下游预处理继续严格检查补齐后的 1920×1080，不放宽张量大小或帧匹配条件。
原图 DDR 路仍保留参考工程的边界 marker 和 RGB565 格式。

CPU 和独立预处理自检中的尺寸预判均已删除；默认仍为 `firmware/video_diagnostic/`。
固件新增 RAW/AI 模式：RAW 只持有完整原图，AI 才抓取配对张量并读回检查。
诊断固件、ROM/RAM 镜像及厂商 IP 内嵌初值同步，不能用旧位流测试新逻辑。
RK 工具更新了错误提示；重新复制 `csrc/rk_fspi/` 后在 RK 本机运行 `make all`。

检查命令：

```sh
python3 scripts/check_hdmi_padding.py
```

该检查只运行行补齐、原始尺寸监测，以及一帧 1919×1080 白图到 96×96 张量的验证。
逐项比较全部 18432 个 DDR 数据拍；最后一个横向池化窗口含 19 个白像素和 1 个黑像素，
R/G/B 的期望平均值均为 242，其余窗口为 255。没有重跑 AI 整网或 CoreMark。
结果见 `reports/video_integration/hdmi_padding_checks.json`。

上板后仍用 `sudo ./rk_comm_cli /dev/spidev4.0 video-status`。
不再因测量宽高不等于 1920×1080 停在阶段 2，而是直接尝试实际抓帧。
完整原图、张量大小和同帧匹配检查继续保留；无完整输入仍会在抓帧阶段超时。
若自检已在 ERROR，执行 `video-retry` 重试。实际抓帧、AI 和 PCIe 闭环仍需上板确认。

上一版 PDS 流程日志在 `build/hdmi-padding/pds_flow.log`。上一版实现记录在
`reports/video_integration/hdmi_padding_implementation.json`，区分位流生成和时序是否通过。
它不代表后续去门控/模式切换修改已经生成位流。PDS 原始资源、时序分别看 `place_route/acore_dual_top.prr` 和
`place_route/acore_dual_top.rtr`，请核对时间。

建议提交消息：`fix: 支持1919像素HDMI输入并统一原图与AI补齐通路`。
