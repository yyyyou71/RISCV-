# HDMI 抓帧与纯 SPI 终端诊断

> 当前固件在视频通过后还会运行真实模型第 1 层并输出 [ai] 状态，默认已启用 AI。
> 新增范围见 [P3a 说明](ai_first_layer_p3a.md)。AI 运行时拒绝 video-release/retry，新增 ai-status。

当前根 rv32I.pds 的 ROM/RAM 初始化选择 firmware/video_diagnostic/。
运行双发射 Acore、视频自检和纯 SPI 消息服务，不运行 CoreMark。
RK 工具位于 csrc/rk_fspi，只连接 SPI 即可收消息、查询和重试，不使用 IIC。
原有 IIC RTL 留在工程内；本固件不访问它。CPU、HDMI、DDR、SPI/IIC RTL 保持；
P3a 开启原有 AI，并适配新生成的乘加 IP 端口。
groute_seed=3，顶层仍为 acore_dual_top，STANDALONE_CAPTURE=1。

## 上板操作

1. 重新打开根 PDS，从 Compile/综合开始，完成布局布线，生成新位流并下载。
   两个 IP 已重新选择新诊断 HEX 并核对嵌入内容，无需手动选初始化文件。
   旧位流仍包含旧程序，独立 SPI 回环位流也不能运行此软核应用。
2. 接 HDMI 和 RK 的 SPI。沿用现有 SCK L19、CS L20、
   DQ0 N22、DQ1 M22、DQ2 M18、DQ3 L18、1.8V 约束。
   默认独立模式不依赖 PCIe 枚举，仍关闭 PCIe 原图读出，SPI 通信不受影响。
3. 复制 csrc/rk_fspi 的源码到 RK，在该文件夹内执行：

    make all
    ./rk_comm_cli /dev/spidev4.0

路径按实际 spidev 调整。不要把 WSL 生成的 x86 二进制当作 RK ARM 程序运行。
只需要这个文件夹，不需要相邻的 rk_iic 目录。
默认终端约每 10 ms 轮询一次，显示软核排队的文本和约每秒一次的视频状态。
CPU 错误后服务继续响应；不是 UART RX 桥接，也不自动截获任意 printf。
应用用 rk_comm_send() 发送文本；当前视频启动、捕获、失败、成功均已接入。

按 Ctrl+C 停止监听，再运行下列命令。不要让监听器和命令进程同时占用 SPI。

    ./rk_comm_cli /dev/spidev4.0 video-status
    ./rk_comm_cli /dev/spidev4.0 video-retry
    ./rk_comm_cli /dev/spidev4.0 video-status
    ./rk_comm_cli /dev/spidev4.0 video-release

video-status 显示实际测到的宽高、最近帧周期、错误阶段、失败快照、预处理与 DDR 窗口状态。
video-retry 重新尝试一次；如果已有成功结果，先异步释放，再等待下一帧。
video-release 释放结果并停在 IDLE。命令接收成功不等于硬件已经完成动作。
status 显示通信包数、日志积压和丢弃数；get/set 保留 16 个参数槽，0 为 GPIO。
once 只打印一条日志/视频消息后退出，logs 为持续监听的别名。

## 自检状态机

启动自动等 DDR ready（最多 3 秒），再等 1920×1080（最多 10 秒），然后抓取一帧，
核对原图/张量描述符、通过 CPU DDR 窗口读回张量首/末像素并检查 RGB INT16 补零格式。
捕获、读回、释放的 CPU 等待期限各为 250 ms。
通信和视频使用协作式状态机，没有等待视频或错误闪码的阻塞循环。

SUCCESS_HELD 表示该次自检成功、原图和张量仍持有，LED1 每 0.5 秒翻转。
ERROR 保存失败时快照，继续输出诊断；错误不再通过 LED0 发送组闪码。
阶段 1..8 与旧闪码对应：DDR、尺寸、启动、硬件错误、抓帧超时、描述符、
首像素检查、末像素检查；新增 9 为释放失败/超时。阶段 2 现在是十秒等待期限。

last measured 和 last frame hz 是最近锁存结果，不保证输入此刻仍在运行。
仍使用已有 0x3061c/0x30620，没有新增像素时钟活性、VS/DE 计数或 HDMI 配置完成寄存器。
0x0 不能单独区分无像素时钟、无 VS/DE 等原因。失败快照为零而当前尺寸已正常时，
可能是视频在自检超时后才稳定，可 retry。帧周期按 25MHz 换算，60Hz 约 416667 ticks。
硬件 BUSY 时拒绝 retry/release；预处理/DDR 窗口 FAULT 锁存时需要协调板级复位，
不会为重试强行复位 DDR 或中断已接受的原生事务。

## 纯 SPI 协议和并发处理

保留已经跑通的底层方式：50MHz、Mode3、四线、SMDT 单段 payload-only ioctl。
用户态不额外添加 00/80，线上命令行为沿用原工具；所有应用收发固定 256 字节。
16 字节头：SPT1、32位序号、16位类型、16位有效负载长度、32位 FNV-1a 校验，
之后为最多 240 字节有效负载，其余补零。校验覆盖头和有效负载，跳过校验字段。
不同 magic 用于区分旧 IIC+SPI 客户端，不能混用。

类型 8000=READY（ABI、帧长、所有权、包数、日志丢弃数），8001=文本，
8002=视频状态，8003=命令响应。CPU 自动 ARM RX，RK 看到 READY 后才写命令；
响应负载为 status/op 各 32 位，加对应操作的数据。请求类型 1=set、2=get、
4=通信状态、5=视频状态、6=retry、7=release。
状态/参数 ABI 延续文档定义，纯 SPI 通道 ABI 为 00010000。
RK 空轮询得到整帧 FF 时等待下一轮，不需要 IIC 或额外 ready 引脚。

CPU RAM 收发缓冲仍由现有 FSP2 所有权保护。日志在完整 SPI 读出后才出队，
发送所有权不释放前不会覆盖。RK 轮询可能打断 CPU 填 TX，所以提交前额外检查
忙/拒绝状态，保证部分写入的数据不会发布；失败时保留软件包，在空隙重写。
ARM/COMMIT 成功用所有权确认，避免空轮询的全局拒绝标志造成误判。
日志 FIFO 512 字节，满时丢弃新尾部并统计；CRC 检出后不重放已执行的命令，
没有端到端日志重传保证。ioctl 返回短传输/错误或应用帧校验失败时报告错误，
用户根据现场状态协调恢复，不自动重复带副作用的命令。
CS 高期间无需 SCK，沿用底层工具的帧间间隔。每次数据完成靠硬件 toggle 通知 CPU。

视频状态负载仍是 28 个小端 uint32：
0..4 ABI/状态/阶段/当前周期/状态经过周期；
5..9 shape/帧周期/PP状态/PP错误/写入字节；
10..12 原图邮箱/DDR窗口状态/窗口错误；
13..16 失败时 shape/帧周期/PP状态/PP错误；
17..21 frameID/raw槽/原生地址/张量逻辑地址/字节；
22..23 retry次数/失败周期；24..27 首末像素各两字。
视频 ABI=00010000，状态0..8分别为 IDLE/WAIT_DDR/WAIT_VIDEO/CAPTURE/
READ_FIRST/READ_LAST/SUCCESS/ERROR/RELEASING。寄存器顺序采样不是硬件原子快照，
32位周期计数在约171.8秒回卷，长时间停留的 elapsed 也会回卷。

## 构建和验证边界

    python3 scripts/build_firmware.py --application video_diagnostic --core acore_dual --image-dir firmware/video_diagnostic
    make -C csrc/rk_fspi all test

新固件使用 firmware/rk_spi_comm.c，不链接旧 firmware/rk_comm.c 的 IIC 服务。
旧 fspi_service 和 comm_service 镜像保留，不能配合当前纯 SPI 终端。
GCC10.2、O2、RV32IM -mno-div；text/data/BSS 以 manifest 对应 ELF 的 size 为准。
本次只编译固件/主机程序、运行主机 mock 检查、静态检查及核对 IP 初始化。
未运行 RTL 仿真、PDS 实现或生成新位流，纯 SPI CPU 通道和新抓帧流程等待用户板级验证。
projects 下已跑通的回环工程保持原样；不能用它的板级结果替代新应用验收。

建议提交：feat: 增加纯SPI软核终端和HDMI抓帧诊断重试。
