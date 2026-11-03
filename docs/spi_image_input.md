# SPI 图片输入：实现与运行

分支 `codex/spi-image-input`；原 HDMI 版本保留在 `ziguang_rv32i@15c1e4f`。
仅维护根 `rv32I.pds`，活动顶层仍为 `acore_dual_top`。

## 数据流程

```text
RK 本地图片 → 解码、缩到 384×216 RGB888 → SPI 分块上传、校验 → DDR
                                                              ↓
                                                 FPGA 读取同一张图片
                                                  ├─ RGB565 原图 → DDR 槽 0
                                                  └─ AI：96×96 均值缩图 → 张量
                                                                     ↓
                                                   99 任务推理 → CPU 后处理
                                                                     ↓
                                              FPGA 原图叠前 16 框 → PCIe → RK 窗口
检测结果全部经 SPI 查询并在 RK 终端打印。
```

RAW 模式生成原图后直接回传；AI 模式增加预处理、推理和画框。
一张图片显示完成并释放后才上传下一张。模型只需上传一次，释放图片会保留模型；FPGA 复位后重新加载。
程序分别打印上传、准备、推理/结果和回图耗时，不用 SPI 标称速率推算整机帧率。

本分支活动构建已移除 HDMI 输入端口、接收实例及相关时钟约束。
保留 `u_video.u_hdmi_fifo.u_ddr3` 名称，以沿用已验证的 DDR PHY 位置和时钟约束；该名字不表示还在从 HDMI 采图。
双发射 Acore、AI 运算引擎、DDR/PCIe IP 和 RK 原 DMA 接口继续复用。

## RK 运行

复制整个 `csrc/rk_fspi/`，包含 `video/`、`third_party/`、全部 `.c/.h` 和 Makefile。
模型 `build/board-ai/board_model.bin` 另放在该目录。
也可解压 `build/spi-image/rk_spi_image_bundle.zip`，内含源码和模型。
在 RK 桌面终端本机编译；WSL x86 可执行文件不能用于 RK：

```sh
cd ~/workspace/rk_fspi
make clean
make all

# 先检查原图链路
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images/test.jpg --output raw

# 加载模型，对目录中每张图执行 AI，显示 FPGA 画框结果
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images --output ai --model board_model.bin

# 同一 FPGA 会话中复用模型，循环目录，处理 20 张后退出
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images --loop --frames 20 --output ai --use-loaded-model

# 只有 SSH 时保存结果，不打开窗口
sudo ./rk_video_app /dev/spidev4.0 --input ./images/test.png --output raw --headless --save result
```

图片路径属于 RK 文件系统。支持 JPG/JPEG、PNG、BMP、二进制 PPM/PGM，任意常用尺寸会缩放到 384×216。
默认 RAW，文件/目录默认处理一遍，目录按文件名排序；`--loop` 才重复，`--frames N` 限制总张数。
`--save PREFIX` 另存 `PREFIX-0000000001.ppm` 等文件；`--wait-ms` 控制等待期限，默认 120000。
模型不是图片，应放在图片目录外。一个进程独占 SPI，不要并行启动旧车牌或其他 SPI 客户端。

正常输出包括：

```text
SPI image input ready: 384x216 RGB888; awaiting upload.
[input] file=...
[input] frame=1 upload=... prepare=... hw_cycles=... RGB888=248832 RGB565=165888
[network] frame=1 task=.../99 state=...
frame_id=1 run_id=... model_session=... detections=...
class,score,model_x1,...,original_x1,...
[present] frame=1 run=... boxes=...; receiving PCIe image
[frame] displayed=1 ... bytes=165888
```

RAW 不运行整网或打印检测结果。启动日志可能在下一次 SPI 轮询时才读出。
呈现 MMIO 状态 bit 6 表示 PCIe 已应答且 DDR 读出器已启动，RK 必须等到该位与 busy(bit 0) 同为 1 再开始 DMA。
bit 5 是故障锁定，不能用作正常就绪条件。本次握手修复需同时更新 FPGA 位流和 RK 程序；软核固件透传状态，不需要修改 C 程序。
短测现已将实际呈现控制器接入 RAW DDR 读出、叠框和输出 FIFO，并使用与 RK 一致的 busy+prepared 条件启动模拟 DMA。
另测仅 busy 时等待、故障锁定时禁止 DMA；物理 PCIe IP、RK 驱动及整机回图仍需上板验证。
上电只等待 SPI 上传，不会因缺少 HDMI 输入而自动抓帧失败。
退出主程序后可查询 `rk_comm_cli /dev/spidev4.0 image-status`、`network-status`、`present-status`，或用 `video-release` 释放。
均需按设备权限使用 sudo。旧 `video-retry` 不用于本分支。
未确认的写入/DMA 不自动重放；DDR 原生接口故障锁定后需要复位 FPGA。

### 模型提交失败（4099 / 0x1003）

这是模型头或后处理配置校验失败，尚未进入网络推理。上传 FNV 来自收到的字节，每块写入后也会立即读回比较；
它不等于上传完毕后再对整份 DDR 模型做一次校验，不能据此排除后来覆盖、地址别名或读出异常。
完整网络计算仿真预先装入了模型，不能代替实板 SPI 上传、DDR 保留和 COMMIT 的验收。

诊断固件保留原有全部校验条件，失败时通过 SPI 打印当时实际读到的两行：

```text
Model validation failed: DDR header words ...
model: 314d4941 ...  (16 words)
post:  31504941 ...  (16 words)
```

RK 程序在明确收到提交拒绝后只读轮询 300 ms，取出响应之后排队的日志。
字段顺序为 `ai_model_header` / `ai_post_config`，本模型预期值见 `reports/spi_image/model_commit_diagnostic.json`。
需要重新实现烧录含新软核固件的根工程，并更新 RK 源码、执行 `make all`。先用 `--frames 1` 测试即可。
这次增加的是定位手段；实际哪一个字段异常，需要新的上板日志确认。

## RTL 与固件

`rtl/video/spi_image_capture.v` 通过 CPU/DDR 双时钟邮箱接受已提交图片。
内部像素处理使用已有 DDR core 时钟域，不增加外部像素时钟。
一个 `ddr_block_transfer` 依次处理输入读取、RAW 写入和张量写入，每条命令保持完整突发所有权。
像素按共同接收条件分给原图和预处理；暂停时不推进坐标，保证两路同帧。

| 数据 | AI 逻辑 DDR 基址 | 有效字节数 |
| --- | --- | ---: |
| 输入 RGBX8888 | `0x03e00000` | 331776 |
| 张量 INT16 HWC-align16 | `0x03f00000` | 294912 |
| RAW RGB565 | 视频槽 0（原生基址 0） | 165888 |

输入/张量物理字节地址分别为 `0x07e00000`、`0x07f00000`，模型/激活区仍限制在逻辑低 32 MiB。
RAW 保留参考读出器的原生突发间隔，不能将其视为连续物理字节区。
每 192 字节 RGB888 打包成 256 字节 RGBX8888，整帧 1296 块，CPU 每块写入后读回比较。
RAW FIFO 复用紫光 16→128 IP，张量使用新紫光 128→128 `spi_tensor_fifo` IP，行累加使用 `pango_pool_sum_ram`。
整张图片保存在外部 DDR。

`rgb888_pool96_stream.v` 只在 valid/ready 同时成立时推进输入位置。
每输出像素取 4 列、3 行；纵向区间按 floor/ceil 自适应划分，前四格是 `[0,3)`、`[2,5)`、`[4,7)`、`[6,9)`。
各通道精确求 12 像素均值，采用最近偶数舍入，按 RGB 写为 INT16，并补齐到 16 通道。
每像素两个 128-bit 字，共 18432 字；均值流水线和输出均可等待。

单帧成功必须确认输入全读、RAW 全写，以及 AI 模式下池化结束、张量全写。
最后一个 DDR 写命令完成后才发布有效帧，不等待下一张图片，不用 magic 像素占用行首/行尾。
保留期间禁止覆盖，PCIe 持有期间拒绝释放。
`frame_ring_ddr3.SPI_IMAGE` 分支在图片处理期间使用原视频原生端口，处理结束且命令排空后交给 PCIe 读出器。
CPU/AI 继续使用另一仲裁端口，DDR IP 参数未修改。

`video_present_control`、`ddr3_read_ctrl`、画框和 RK 坐标/长度统一为 384×216。
RK 确认对应帧号和完整 10368 个 128-bit 字后显示。硬件最多画置信度前 16 框，SPI 保留全部结果。
固件上电等待命令，模型上传不依赖已抓到第一帧。

## 命令协议

保持 SPT1 固定 256 字节传输。整数为小端，整帧 FNV-1a 覆盖全部 RGB 字节。

| 操作 | 请求 |
| --- | --- |
| 19 IMAGE_STATUS | 无负载；返回 20 字状态，首字 ABI `0x00010000` |
| 20 IMAGE_BEGIN | session、frame_id、384、216、format=1、248832、整帧 FNV、flags=0，共 8 字 |
| 21 IMAGE_DATA | session、frame_id、源 RGB 字节偏移，再跟 192 字节 RGB888 |
| 22 IMAGE_COMMIT | session、frame_id、248832、整帧 FNV，共 4 字 |
| 23 IMAGE_ABORT | session、frame_id；尚未处理的上传可放弃，处理中返回 BUSY |

状态为 EMPTY、UPLOADING、PROCESSING、READY_HELD、ERROR、RELEASING。
BEGIN 登记事务，DATA 应答确认 DDR 读回一致，COMMIT 校验整帧后才排队硬件处理。
现有操作 13 执行推理、17 准备回图、7 释放图片、18 选择 RAW/AI。
硬件状态位：BUSY=1、DONE=2、ERROR=4、HELD=8、DDR_READY=16、FAULT=32。
`0x30838` 返回 `0x53494d31`，用于拒绝旧 HDMI 硬件/新固件混配。
`image-status` 显示会话、帧号、偏移、校验、原图/张量字节数、硬件错误和耗时。

## 验证结果及报告

2026-11-03 已通过：

- 384×216 RAW/AI 整帧 RTL：全部原图/张量数据、均值舍入、DDR 停顿、单帧完成和帧锁定。
- 小尺寸 RAW 集成：实际 DDR 行为模型、共享仲裁、原图写入、画框及面向 PCIe 的异步 FIFO。
- 执行真实软核 C 服务的主机检查：RGBX 打包/读回、偏移错误、校验失败、提交、同帧推理接口、展示和释放。
- RK 主机检查：1296 块上传、目录 RAW/AI 流程、图片解码/缩放和错误长度/帧号/旧 ABI 拒收。
- RV32 编译，ROM/RAM IP 所有初始化字核对；PDS 编译/综合，最终日志无 `E:`。

本轮复用已有 AI 算子，不重跑完整模型长仿真。
物理 SPI、PCIe DMA、RK ARM 运行和实际识别结果仍需上板验证，短仿真不能替代。

| 综合估算资源 | 使用 / 总量 | 比例 |
| --- | ---: | ---: |
| LUT | 38232 / 66600 | 57.41% |
| 寄存器 | 33274 / 133200 | 24.98% |
| DRM36K 等效 | 84.5 / 155 | 54.52% |
| APM | 21 / 240 | 8.75% |

完整报告：`synthesize/acore_dual_top.snr`；日志：`build/spi-image/pds_flow.log`；摘要：`reports/spi_image/validation.json`。
本轮只到综合，没有新的布局布线结果或 `.sbit`；原 `generate_bitstream` 中的旧位流不是新 SPI 结果。
继续根项目的器件映射、布局布线和位流生成后，读取 `place_route/acore_dual_top.prr` 和 `.rtr` 确认最终资源及 setup/hold。

复现短检查：WSL 仓库根目录执行 `python3 scripts/check_spi_image.py`。
固件重建：`python3 scripts/build_firmware.py --app spi_image --core acore_dual --image-dir firmware`；
随后 Windows 执行 `python scripts/select_acore_firmware.py --image-dir firmware` 同步 IP 初始化。
固件 text=22984、data=808、BSS=2072 字节，沿用 32 KiB ROM、64 KiB RAM，并保留至少 16 KiB 栈空间。

建议提交消息：`feat: add SPI image input with FPGA preprocessing and PCIe results`。
