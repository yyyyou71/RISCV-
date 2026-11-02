# RK SPI、PCIe、模型加载与窗口显示

入口是 `csrc/rk_fspi/rk_video_app.c`。复制整个 `csrc/rk_fspi/` 到 RK，保留 `video/`。
在 RK 桌面终端本机编译运行，显示选择按本轮确认使用 SDL2 窗口。

```sh
cd ~/workspace/rk_fspi
make clean
make all
sudo -E ./rk_video_app /dev/spidev4.0 --output raw --frames 30
```

预览成功后，将 PC 上 `build/board-ai/board_model.bin` 另行复制到同目录：

```sh
sudo -E ./rk_video_app /dev/spidev4.0 --output ai --model board_model.bin
```

一条命令完成：SPI 上传模型 → 软核逐块写入/读回 DDR → 整包校验 → 同帧抓取原图和张量
→ 99 任务推理与后处理 → SPI 打印全部检测结果 → FPGA 叠加前 16 框
→ PCIe 接收 1920×1080 RGB565 → RK 窗口显示 → 请求下一帧。
模型加载一次，每帧重新推理；按串行单帧协议工作，不承诺 60 FPS 显示或推理。
模型上传完成后会重新抓取新帧，避免把上传前的启动自检图像当作第一张推理图。
`--output raw`（也是不带参数的默认模式，`--preview` 是它的别名）直接通过原图邮箱
持有已经完整写入 DDR 的帧，再经 PCIe 显示；不启动张量抓取、首层诊断或整网推理。
`--output ai` 持有同帧原图和 294912 字节张量，加载模型后运行推理与画框。
`--model` 和 `--use-loaded-model` 在没有显式模式参数时会自动选择 AI。
固件上电默认 RAW，不再自动运行首层诊断。两端都需要更新，旧位流不支持模式选择命令。
切换方式为退出当前程序，再用另一种 `--output` 模式启动；AI 模型在不复位 FPGA 时保留。
切换时先完成已知排队帧的接收，再释放旧帧、切换持有协议；不会在 DMA/推理中强行释放。

`board_model.bin` 是包含权重、任务、激活空间和后处理配置的完整打包文件，当前为
13,372,720 字节。SPI 使用固定 256 字节帧，每块承载 224 字节模型数据。
确认上传成功后才启动推理；发生未确认写入时不自动重发，保留已有显式恢复流程。

```sh
# 同一 FPGA 会话中继续使用已加载模型
sudo -E ./rk_video_app /dev/spidev4.0 --output ai --use-loaded-model
# 从软核已确认的上传偏移继续同一个文件
sudo -E ./rk_video_app /dev/spidev4.0 --model board_model.bin --resume
# 只接收 10 帧；另存 PPM 图像
sudo -E ./rk_video_app /dev/spidev4.0 --preview --frames 10 --save capture
# 不打开窗口，供只有 SSH 时检查一帧
sudo ./rk_video_app /dev/spidev4.0 --preview --headless --save capture --frames 1
```

默认持续运行，关闭窗口或 Ctrl+C 退出。`--wait-ms` 设置推理等待期限，默认 120000。
保存文件名包含 FPGA `frame_id`，例如 `capture-0000000042.ppm`。
正常日志包括 `[capture]`、`[network]`、检测结果 CSV、`[present]`、`[frame]`；
宽高测量仅作诊断，不再用于起采门控；即使测量异常也会尝试实际抓帧。
输入行尾补黑到 1920；进入显示的图像为 1920×1080，仍需完整帧和 DMA 字数检查通过。
取消预判不代表已经修好输入信号；没有完整写入 DDR 的原图仍会超时。

## 复用范围与时序配合

`video/pcie_dma.c/.h` 和 `video/display.c/.h` 从桌面 `yolo-i8` 移入，来源校验记录在
`video/reference.json`。保留 BAR1 命令布局、CMA cached DMA、原驱动回退和 RGB565/SDL2 显示。
没有引入旧 RKNN、LPRNet 或颜色识别处理。

为了配合当前受控单帧发送，做了以下适配：

- 先检查 SPI 侧 presentation 已锁定对应帧，再下发 PCIe DMA 命令。
- 不在启动时做 PCIe function reset；启用 COMMAND 时保留其他位，并检查真实 BAR1
  与 Linux resource 地址一致。发现未重新枚举的 BAR 不匹配时明确退出。
- presentation 排队之后不复位 DMA，以免丢掉已预取的图像数据；已有待发送帧时也不做启动复位。
- DMA 完成后还核对软核确认的 frame_id 和完整 259200 个 128-bit 数据字，再显示。
- 下一帧由 `video-retry` 释放并重新抓取：RAW 使用原图邮箱，AI 使用原图/张量配对协议。
- 模型上传期间继续处理窗口事件；SPI 由一个进程独占，不需要同时开两个终端工具。

## 构建与验证边界

`make all test` 包含原 SPI 客户端检查，以及共享控制库和整合程序的主机状态机测试。
主机测试覆盖上传/校验/显式恢复、连续两帧 RAW、RAW/AI 双向切换、AI 自动排队、
切换前排空已知帧、frame_id/数据长度不一致时拒绝显示，以及旧固件不支持模式协议时退出。
这些检查在 WSL x86_64 上执行，不代表在 RK ARM 或 PCIe 实物上验证通过。
ARM 缓存维护、CMA heap、DMA ioctl 和 SDL2 运行依赖沿用原车牌程序，需要 RK 上实测。
首次上板建议先用 `--preview --frames 1 --save capture`，再运行 `--model`。

FPGA 仍使用根工程 `rv32I.pds`，本轮 HDL 改动和位流检查见 [HDMI 1919 像素适配](hdmi_padding_1919.md)。

## 模式协议

SPI 操作 18（`COMM_VIDEO_MODE`），无负载查询，4 字节小端负载设置：0=RAW，1=AI。
响应是 4 个小端 uint32：ABI `0x00010000`、当前模式、请求模式、视频状态。
接受切换后可能暂处于 RELEASING，客户端等当前模式一致再处理帧。
原有 video-status 的 28 字布局保持：RAW 的 tensor_base/bytes 为 0，AI bytes 为 294912；
第 7 字为当前捕获路径状态，RAW 邮箱位已转换为与 PP 一致的 BUSY/DONE/ERROR/HELD 位。
原图实际 PCIe 长度始终为 4,147,200 字节，不等于这里的张量 bytes。
