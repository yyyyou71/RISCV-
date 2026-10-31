# RK 纯 SPI 终端

配合根工程 rv32I.pds、固件 firmware/video_diagnostic/ 使用。
这是 CPU 消息通道，不是 projects 下的独立硬件回环。
只需复制本目录源码到 RK，不依赖 csrc/rk_iic，也不需要连接 IIC。

在 RK 本机编译（不要复制 WSL 的 x86 可执行文件）：

    make clean
    make all
    ./rk_comm_cli /dev/spidev4.0

默认持续读取软核日志并打印到终端，每秒左右显示视频/AI 状态。
Ctrl+C 停止监听后，可以执行：

    ./rk_comm_cli /dev/spidev4.0 video-status
    ./rk_comm_cli /dev/spidev4.0 ai-status
    ./rk_comm_cli /dev/spidev4.0 video-retry
    ./rk_comm_cli /dev/spidev4.0 video-release
    ./rk_comm_cli /dev/spidev4.0 status

仍支持 get INDEX / set INDEX VALUE（0..15）；0 为 GPIO，可能被视频应用后续更新。
once 只等待并打印一条日志/视频消息；logs 是持续监听的别名。
重试命令返回接收成功后，用 video-status 或监听观察实际完成结果。
设备路径按 RK 实际设备调整；同一时间只运行一个客户端，设备锁避免合作客户端竞争。

沿用已验证 SMDT 接口：50MHz、mode3、按读写分别设置 quad 标志、单段 payload-only transfer。
没有修改 projects/fspi_test_50m/rk_tool 或其独立位流。
rk_fspi.c 默认关闭每次 ioctl 的刷屏输出；需要时用 make CPPFLAGS=-DRK_FSPI_TRACE 重建。
若已有目标文件，先 make clean。主工程应用帧固定 256 字节，SPT1 头部和校验在 payload 内，
无需 IIC 通知或额外 ready 管脚。软核先缓存消息，RK 作为主机提供 SCK 轮询读取。

make test 仅运行主机 mock 检查。
原 rk_fspi_demo 保留为人工协调的原始读写工具，不要与 rk_comm_cli 并行使用，
也不能把原始回环比较结果当作 CPU 终端协议的结果。
详见 [HDMI 诊断说明](../../docs/video_spi_diagnostic.md)。
