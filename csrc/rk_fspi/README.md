# RK 纯 SPI 终端

## SPI + PCIe + RK 桌面窗口

新增单一程序 `rk_video_app`，包含 SPI 模型上传/控制/结果、PCIe 图像接收、SDL2 窗口显示。
将整个本目录（包含 `video/` 子目录）复制到 RK；在 **RK 桌面终端**中执行：

```sh
make clean
make all
sudo -E ./rk_video_app /dev/spidev4.0 --output raw --frames 30
```

先验证预览，再将 PC 上 `build/board-ai/board_model.bin` 复制到本目录，执行：

```sh
sudo -E ./rk_video_app /dev/spidev4.0 --output ai --model board_model.bin
```

该命令先通过 SPI 上传并校验整个模型包，然后循环抓帧、FPGA 推理、打印检测结果、
PCIe 接收同帧带框 RGB565 图像并显示。推理后才抓下一帧，显示帧率由完整处理周期决定。
模型必须是 `prepare_board_model.py` 生成的包，含权重、99 个任务和后处理配置，
不能用 `.rknn` 或原始训练权重替代。
如模型已经成功加载，使用 `--use-loaded-model`，避免重新上传。

原图模式直接持有 DDR 原图，不启动张量预处理或 AI；`--preview` 仍保留为原图模式别名。
固件上电默认原图模式。退出程序后换另一种 `--output` 重新启动即可切换；
已加载模型在 FPGA 不复位时保留。两端必须一起更新，并生成/烧录包含新固件的新位流。
宽高诊断不再门控起采，但完整帧、同帧匹配和 PCIe 长度检查仍保留。

`-E` 保留桌面 `DISPLAY` 等环境变量；普通 SSH/串口终端不一定能打开桌面窗口。
运行时使用已有 SDL2 动态库，编译无需 SDL2 开发头文件、RKNN 或交叉编译器。
本仓库在 WSL 上编译的可执行文件用于编译检查，必须在 RK 上重新 `make all`。
同一时间只运行本程序，不要同时运行旧 `video_output` 或其他 SPI 客户端。

更多参数、诊断和验证边界见 [整合程序说明](../../docs/rk_video_app.md)。

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
infer 需要 AI 模式已经持有有效原图/张量；默认 RAW 不能直接 infer，建议使用上面的 rk_video_app 命令。
运行后查询到 DONE 才读取结果。
断传不自动重发，可 status 后显式 resume 同一文件，或 abort 取消装载。
见 [P3b 说明](../../docs/ai_network_p3b.md)。本次模式切换完成主机检查，仍待 RK/FPGA 实测。

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
