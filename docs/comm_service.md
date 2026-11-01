# CPU 通信服务

当前 `firmware/fspi_service.c` 和 `firmware/video_diagnostic.c` 均使用
`firmware/rk_spi_comm.c`，直接经 SPI 收发 SPT1 帧，无需 IIC 协商。
旧混合 IIC/SPI 协议与旧预编译镜像已清理。

构建和接口见 [RK 与 Acore 通信](rk_cpu_link.md)；实板诊断见
[SPI 视频诊断](video_spi_diagnostic.md)。
短检查：`python3 scripts/check_comm_service.py`。
