# RK 本地图片、SPI 输入与 PCIe 显示

当前 codex/spi-image-input 分支从 RK 本地图片输入。
完整设计、协议和验证记录见 [SPI 图片输入说明](spi_image_input.md)。

```sh
cd ~/workspace/rk_fspi
make clean
make all
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images/test.jpg --output raw
sudo -E ./rk_video_app /dev/spidev4.0 --input ./images --output ai --model board_model.bin
```

复制目录时包含 video/ 和 third_party/，模型另行复制；也可使用 build/spi-image/rk_spi_image_bundle.zip。
RK 本机编译，窗口在 RK 桌面显示。输入统一为 384×216 RGB888，FPGA 硬件预处理到 96×96，PCIe 返回 384×216 RGB565。
--loop 重复目录，--frames N 限制张数，--save PREFIX 保存 PPM；--headless --save PREFIX 用于没有桌面的环境。
RAW 跳过张量和推理；AI 复用模型、运行推理并由 FPGA 画最多 16 框，SPI 返回全部检测结果。
不复位 FPGA 时，后续使用 --use-loaded-model。
诊断使用 image-status、network-status、present-status 和 video-release。
原 HDMI video-retry 用法保留在 ziguang_rv32i 分支。
