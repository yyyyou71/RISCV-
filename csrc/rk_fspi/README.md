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
    ./rk_comm_cli /dev/spidev4.0 network-status
    ./rk_comm_cli /dev/spidev4.0 present-status
    ./rk_comm_cli /dev/spidev4.0 present
    ./rk_comm_cli /dev/spidev4.0 video-retry
    ./rk_comm_cli /dev/spidev4.0 video-release
    ./rk_comm_cli /dev/spidev4.0 status

仍支持 get INDEX / set INDEX VALUE（0..15）；0 为 GPIO，可能被视频应用后续更新。
once 只等待并打印一条日志/视频消息；logs 是持续监听的别名。
重试命令返回接收成功后，用 video-status 或监听观察实际完成结果。
设备路径按 RK 实际设备调整；同一时间只运行一个客户端，设备锁避免合作客户端竞争。

完整模型工具（仅复制本目录即可编译）：

    ./rk_model_cli /dev/spidev4.0 load board_model.bin
    ./rk_model_cli /dev/spidev4.0 status
    ./rk_model_cli /dev/spidev4.0 infer
    ./rk_model_cli /dev/spidev4.0 results

board_model.bin 用 scripts/prepare_board_model.py 在 PC 生成后另行复制。
infer 需要已经持有有效 HDMI 帧；运行后查询到 DONE 才读取结果。
断传不自动重发，可 status 后显式 resume 同一文件，或 abort 取消装载。
见 [P3b 说明](../../docs/ai_network_p3b.md)。RK 暂缺联调条件，当前只完成主机侧检查。

present 使用持有的同帧原图，若有整网结果则画置信度前 16 框，否则发送 0 框原图。
PCIe 已连接时整网 DONE 后会自动排队一次；RK 还需用原工程的 PCIe 接收程序发起 DMA，
接收完整 1920×1080 RGB565（4,147,200 字节）。SPI 命令成功只表示排队，present-status 的 DONE 才表示 FPGA 发送排空。
未连 RK 时不会启动该读取；发送中禁止 video-release/retry，断链或欠载锁住槽位直到全局复位。
每次 present 消耗一帧，下一次先 video-retry。详见 [P4 说明](../../docs/video_present_p4.md)。

沿用已验证 SMDT 接口：50MHz、mode3、按读写分别设置 quad 标志、单段 payload-only transfer。
没有修改 projects/fspi_test_50m/rk_tool 或其独立位流。
rk_fspi.c 默认关闭每次 ioctl 的刷屏输出；需要时用 make CPPFLAGS=-DRK_FSPI_TRACE 重建。
若已有目标文件，先 make clean。主工程应用帧固定 256 字节，SPT1 头部和校验在 payload 内，
无需 IIC 通知或额外 ready 管脚。软核先缓存消息，RK 作为主机提供 SCK 轮询读取。

make test 仅运行主机 mock 检查。
原 rk_fspi_demo 保留为人工协调的原始读写工具，不要与 rk_comm_cli 并行使用，
也不能把原始回环比较结果当作 CPU 终端协议的结果。
详见 [HDMI 诊断说明](../../docs/video_spi_diagnostic.md)。
