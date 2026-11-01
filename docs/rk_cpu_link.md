# RK 与 Acore 通信：纯 SPI

RK 通信用的 IIC 从机、64 字节发送 FIFO、参数邮箱及其 `0x30400–0x30414` MMIO 已删除。
顶层不再提供 `iic_scl` / `iic_sda`，P19/R19 约束已释放。
HDMI 芯片配置继续使用独立的 `hd_scl` / `hd_sda`，不受影响。

当前通道为 50 MHz 四线 SPI、mode 3，SPT1 固定 256 字节帧，带序号和校验。
CPU 驱动在 `firmware/rk_spi_comm.c`；RK 端工具在 `csrc/rk_fspi/`。
当前板级程序仍为 `firmware/video_diagnostic/`，用法见 [SPI 视频诊断](video_spi_diagnostic.md)
和 [RK 工具说明](../csrc/rk_fspi/README.md)。

独立通信服务可重新生成到构建目录，不覆盖当前 FPGA 初始化文件：

```sh
python3 scripts/build_firmware.py --app fspi_service --core acore_dual --image-dir build/fspi-service-images
python3 scripts/check_comm_service.py
```

旧 IIC 服务、混合 IIC/SPI 服务及其预编译镜像已删除，历史实现可从 Git 查看。
