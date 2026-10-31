# 独立 FSPI 上板回环工程

打开本目录 fspi_test.pds，顶层为 fspi_loopback_top。

已在PDS 2022.2-SP6.4完成Compile、综合、映射、布局布线、时序报告及位流生成。
可直接下载 build/generate_bitstream/fspi_loopback_top.sbit（2026-10-30生成）。
仿真通过两轮2KB写入读回及复位检查。内部慢角setup余量29.419ns，快角hold余量0.017ns。
异步SPI输入/输出仍有Timing-4086/4087提示；内部时序通过不代表外部接口已经上板验证。
请先用1MHz、256字节测试，再测2048字节。未进行实际板卡下载。

芯片 PG2L100H / FBG484 / -6，系统时钟25MHz，FSPI四线mode 0、最高1MHz。
这是独立的硬件回环测试，不运行软核、UART、IIC、视频或PCIe，也不需要ROM镜像或IP生成。
原工程、CPU和固件未修改。本目录复制了测试所用RTL，不会随主工程源文件自动更新。

引脚来自当前工程和原FSPI例程：
- sys_clk V4（SSTL15_I，1.5V），key0_n M15（1.8V）
- led0 J16、led1 M17（1.8V）
- spi_clk L19、spi_cs L20、D0 N22、D1 M22、D2 M18、D3 L18（LVCMOS18，1.8V）
只使用这些约束，没有DDR/HDMI/PCIe引脚或PHY时钟约束。

在PDS完成 Generate Bitstream 后，把本测试工程生成的位流下载至FPGA。
不要下载主工程此前生成的位流。不需要焊接回环线；写入与读回通过FPGA内2KB存储完成。
下载后LED0周期翻转；LED1在收到CS活动后改变电平并保持至复位。
LED的亮灭取决于板上有效极性，LED1不代表数据校验通过。

将本目录 rk_tool 复制到RK，在RK终端进入该目录：

    make
    ls /dev/spidev*
    ./rk_fspi_demo /dev/spidev4.0 256
    ./rk_fspi_demo /dev/spidev4.0 2048

必须确认spidev4.0对应实际连接FPGA的控制器。此设备号来自原板卡手册。
成功输出 PASS: 256/2048 bytes quad FSPI loopback at 1 MHz。
该程序先写后读并逐字节比较，不依赖CPU软件和IIC参数；禁止同时运行另一个SPI测试进程。
RK驱动需支持标准spidev四线接口；厂商驱动兼容性仍需板上确认。

本地行为仿真命令（WSL，进入此目录）：

    mkdir -p build
    iverilog -g2012 -s TB_fspi_loopback -o build/test.vvp TB_fspi_loopback.v fspi_loopback_top.v rk_fspi_adapter.v board_reset.v
    vvp build/test.vvp

时序约束保持25MHz内部路径检查；仅对异步输入到采样寄存器作例外。
输出延迟预算100ns用于1MHz低速上板测试，不代替RK/板级建立保持时间测量。
