# RK SPI 图片输入与 PCIe 回图

配合 codex/spi-image-input 分支的根 rv32I.pds 和 firmware/spi_image.c 固件。
复制整个目录，包含 video/、third_party/，再把 board_model.bin 放在本目录。
在 RK 桌面终端本机编译；不要使用 WSL 生成的 x86 可执行文件：

```sh
make clean
make all
# 原图链路
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images/test.jpg --output raw
# AI + FPGA 画框 + PCIe 显示，模型上传一次
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images --output ai --model board_model.bin
# 复用模型，循环目录，最多 20 张
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images --loop --frames 20 --output ai --use-loaded-model
# 无窗口保存 PPM
sudo ./rk_video_app /dev/spidev4.0 --input ./images/test.png --output raw --headless --save result
```

支持 JPG/JPEG、PNG、BMP、二进制 PPM/PGM。图片存于 RK 任意可读目录，由 --input 指定。
RK 解码并缩放到 384×216 RGB888，FPGA 完成 96×96 预处理和推理；PCIe 返回 384×216 RGB565。
默认 RAW，文件/目录默认处理一遍；--loop 才重复，--frames N 限制总张数。--save PREFIX 另存结果。
同一时间只运行一个 SPI 客户端。程序需要新 SPI 图片位流，旧 HDMI 位流会在 ABI 检查时退出。
退出主程序后诊断：

```sh
sudo ./rk_comm_cli /dev/spidev4.0 image-status
sudo ./rk_comm_cli /dev/spidev4.0 network-status
sudo ./rk_comm_cli /dev/spidev4.0 present-status
sudo ./rk_comm_cli /dev/spidev4.0 video-release
```

video-retry 属于旧 HDMI 路线，本版本由图片上传触发。
沿用 SMDT 四线 50 MHz mode 3，不需要 IIC、RKNN、SDL2 开发头文件或交叉编译器。
窗口运行需要 RK 上现有 SDL2 动态库，PCIe/CMA 驱动沿用原工程。
PCIe 回图修复需要重新生成并烧录本版位流，同时重新上传本目录、执行 make all。
RK 等待呈现状态 bit 6（PCIe 已应答且 DDR 读出器已启动）后才开始 DMA；bit 5 是故障锁定，正常回图为 0。
模型由仓库 scripts/prepare_board_model.py 生成，或使用提供的 board_model.bin。
make test 是仓库开发检查，其中软核服务测试需要仓库 firmware/、csrc/software/；只复制本目录时执行 make all 即可。
完整说明在仓库 docs/spi_image_input.md，综合报告在 synthesize/acore_dual_top.snr。
