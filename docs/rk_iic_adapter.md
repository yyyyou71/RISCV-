# 已移除：RK IIC adapter

RK 通信已迁移到纯 SPI，旧 `rtl/rk_iic/`、`csrc/rk_iic/`、IIC 固件及测试已清理。
当前接口见 [RK 与 Acore 通信](rk_cpu_link.md)。历史源码和说明可从 Git 查看。
HDMI 芯片配置所需的 IIC 保留在 `rtl/video/hdmi/`。
