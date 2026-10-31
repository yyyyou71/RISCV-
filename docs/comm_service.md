# CPU/RK SPI 通信应用（2026-10-31）

## 已实现

firmware/fspi_service.c 现在运行 rk_comm_init()/rk_comm_poll() 通信服务，替代原来的测试数据/求和程序。
实际逻辑在 firmware/rk_comm.c，复用现有 FSP2 硬件，无 CPU RTL 或外设 RTL 改动。
RK 命令行 csrc/rk_fspi/rk_comm_cli.c 自动完成 IIC 协商、SPI 写请求、等待 CPU 处理、SPI 读响应。
不需要用户手动先运行 write 再 read。IIC 默认设备由命令行指定（此板为 /dev/i2c-0，地址 0x66），SPI 为 /dev/spidev4.0、50MHz、mode3。

功能：
- set/get：16 个 32 位参数槽；槽 0 的低两位作用于 GPIO，槽 1..15 留给应用读取，不自动改变视频/AI配置。
- logs：读取 CPU 通过 rk_comm_send() 排队的日志/串口字节。512 字节队列，满时拒绝尾部数据并统计丢弃数。
- status：协议版本、收发包数、日志积压/丢弃数、周期计数。
- 报文含版本标识、序号、长度、FNV-1a 校验和；校验不通过不执行参数写入。

这是 CPU 产生的数据上行接口，不是外部 UART RX 转发。当前板顶层没有接出 uart_tx，也没有 UART RX 硬件，不能据此宣称外部串口设备已桥接。
参数默认值为 0、复位后不保存；启动日志为 RV32 communication ready。

## FPGA 固件部署（需要用户操作已有 ROM/RAM IP）

本次已编译新固件，但遵守“IP 操作由用户接手”，没有更改已有 IP 的配置、生成源码或初始化常量。
因此当前 PDS 仍选择旧启动程序；必须切换初始化镜像并重新生成 bit 才能运行本服务。

在 PDS 的已有 IP 中设置 HEX 初始化文件：
- pango_acore_fetch: firmware/comm_service/acore_dual_rom.hex
- pango_acore_ram: firmware/comm_service/acore_dual_ram.hex

只改初始化文件，保持现有宽度、深度、端口、时钟参数；由用户重新生成这两个已有 IP。
acore_dual_ram_bytes.hex 仅用于行为仿真，不要选为 32 位 RAM IP 的初始化文件。
然后重新 Compile/Synthesize/实现，检查时序，生成并下载新 bit。原有 bit 不包含这次新程序。
部署本镜像会选择通信应用，而不是 CoreMark 或 preprocess_bringup；视频硬件和 DDR 接线未改，但本应用不主动启动预处理抓帧。

## RK 使用

保留 csrc/rk_fspi 与 csrc/rk_iic 的相邻目录关系（Makefile 引用 ../rk_iic/rk_iic.c 和 .h）。在 RK 的 rk_fspi 目录执行：

    make clean
    make
    ./rk_comm_cli /dev/i2c-0 /dev/spidev4.0 status
    ./rk_comm_cli /dev/i2c-0 /dev/spidev4.0 set 0 3
    ./rk_comm_cli /dev/i2c-0 /dev/spidev4.0 get 0
    ./rk_comm_cli /dev/i2c-0 /dev/spidev4.0 set 1 115200
    ./rk_comm_cli /dev/i2c-0 /dev/spidev4.0 get 1
    ./rk_comm_cli /dev/i2c-0 /dev/spidev4.0 logs

set 1 115200 只是设置应用参数，不会自动重配 UART 波特率。
logs 可附加最大读取字节数，0..2032；当前队列容量 512。
同一时刻只允许一个通信应用访问 IIC/SPI；不要同时运行旧 rk_iic_demo 参数提交、旧 SPI 回环或 raw rk_fspi_demo。
CLI 使用设备文件 advisory flock 避免合作客户端竞争；不遵守锁的其他程序仍可能干扰。

## 应用调用

    #include "rk_comm.h"
    int main(void) {
        rk_comm_init();
        for (;;) {
            rk_comm_poll();
            /* 应用可读取 rk_comm_parameter(1)，并执行短小的非阻塞工作。 */
            /* 有新数据时调用 rk_comm_send(bytes, length)，不要每圈重复发同一条。 */
        }
    }

编译时将 firmware/rk_comm.c 加入源文件列表。
服务独占 RK_PARAM/RK_ACK、IIC 发送队列与 SPI INDEX/DATA；中断或其他生产者不能交错访问。
日志可与 UART 输出在应用中显式调用两路接口，但本服务不自动截获任意 printf/uart_putc。
保留现有 rk_link.h、旧 IIC 示例以便使用旧固件；新通信固件不再把每个 IIC 参数直接作为 GPIO 值解释。

## 协议与恢复

IIC 参数命令 32 位：[31:24] opcode，[23:16] token，[15:0] argument。
A0=查询 ABI；A1=ARM 接收长度（16..2048）；A2=查询状态和响应长度。
CPU IIC 回复固定 8 字节：C3、token、code、version=1、value 小端 32 位。
A2 value 低16位：0 idle、1 receiving、2 response ready、4 fault；高16位为完整响应长度。
客户端必须完整消费每个控制回复，再提交下一个控制命令。

SPI 包：16 字节头部（magic RVC1、32 位序号、16 位操作码/响应状态、16 位payload长度、32位校验）+ payload。
校验覆盖整个包，跳过头部校验字段的第12..15字节。
操作码1=set（索引、值，各32位），2=get（索引32位），3=logs（最大长度32位），4=status（空payload）。
响应状态0=成功，1=坏包，2=参数错误，3=未知操作。
发送缓冲完整被 RK 读取后 CPU 才移除对应日志并释放状态；RK 若在读取后遇到校验错误，日志可能已消费，并非端到端可靠消息队列。
序号用于响应匹配，不提供去重/自动重放保证。传输失败不自动重试；参数写可能已生效，应先确认状态。
短帧可能保留挂起所有权；CLI 超时后报告不确定状态，不擅自重发或清除。此版本没有在线取消命令，无法协调继续时需板级复位。
IIC 控制命令回复期限3秒；SPI内核ioctl自身阻塞时间由驱动决定。

## 编译和检查

    python3 scripts/build_firmware.py --application fspi_service --core acore_dual --image-dir firmware/comm_service
    python3 scripts/check_comm_service.py
    make -C csrc/rk_fspi all test

- 真实双发射 RV32 执行新固件，经过 CPU MMIO + 50MHz SPI，覆盖参数更新/读取、坏校验无副作用、无效索引/命令、日志消费、状态和所有权释放。
- 应用仿真在 IIC frontend 的应用端注入控制消息并收集回复；不是新的物理 IIC 波形验证。已有 IIC 驱动和硬件前端未修改。
- RK mock 检查控制握手、长度、校验、错误和不自动重试。
- 没有要求重复昨天的硬件回环；新增应用尚需用户切换 IP 镜像后部署。没有生成 bit，没有宣称新版已上板。
- 固件 ROM约2.3KB，初始化数据28字节、BSS4728字节（最终以manifest和ELF size为准）。
