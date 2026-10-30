# FSPI 移植与适配（2026-10-30）

## 已实现与范围

参考本机 fspi_slave_test/fspi_slave_test 原例程和 fpga_rk通信手册v1.pdf 第5–6页。
原工程目标 PG2L50H FBG484；本工程为 PG2L100H FBG484。
保留四线字节协议：CS低、0x00写/0x80读、无地址/无dummy、每字节高4位先传，
每帧从缓冲区地址0开始，最多2048字节。只实现四线，不实现单线/双线或Flash命令。
原例程SPI上升沿采样、下降沿输出；新版按mode 0使用。
手册工具的 -m 3 表示四线模式，不是标准SPI的 CPOL/CPHA mode 3。

原例程依赖400MHz PLL和RAM IP，并存在CS无时钟时部分状态不能复位、
跨时钟域脉冲/数据直接采样、读字节未锁存、越界回绕等适配风险。
新版 rk_fspi_adapter 在25MHz sys_clk统一采样和处理；首次测试 SCK<=1MHz，
SCK高低时间均>=500ns，CS帧间高电平>=1us，CS拉低到首次SCK上升沿>=500ns。
这是低速适配版，不是原例程50/100MHz吞吐能力的实现或验证。
没有生成、添加或例化新的厂商PLL/RAM IP。2KB存储用RTL描述，由综合器决定实现。
资源占用及实际时序必须在PDS中确认。高频版本需另做SCK时钟域收发、CDC和存储架构。

## 工程入口

- rtl/rk_fspi/rk_fspi_adapter.v：采样、四线收发、缓冲区和访问仲裁。
- rtl/peripheral_bus.v / rtl/soc.v：可选 ENABLE_FSPI 接口。
- board/board_fspi_top.v：启用FSPI，同时保留CPU/UART/IIC的顶层。
- rv32I.pds 已登记源码，但仍选择原 board_top；原顶层接口不变，SoC默认不启用FSPI。
- firmware/fspi_link.h：软核缓冲区读写接口。
- firmware/fspi_service.c：通过IIC控制FSPI缓冲区的可运行固件。
- csrc/rk_fspi：标准Linux spidev四线调用和回环测试，含主机mock测试。

首次只做回环无需切换固件。你在PDS中选择 board_fspi_top，核对物理约束后编译。
原 board_top 不增加FSPI引脚；FSPI专用顶层集中在 board_fspi_top。
已有IIC约束不变；FSPI参考约束未自动加入工程，也未生成或下载bitstream。

## 引脚与时序（必须由你在PDS/原理图核对）

原例程：SCK=L19、CS=L20、D0=N22、D1=M22、D2=M18、D3=L18，均LVCMOS18。
见 board/fspi_pins.reference.fdc；只供核对，不要把IIC的3.3V设置复制过来。
确认确实连接RK FSPI且bank电源为1.8V之后，手动激活这些约束。
采样时钟仍是25MHz sys_clk。外部SCK是异步数据输入，不是内部时钟。
需核对到sck_sync/cs_sync/dq_meta第一级的异步路径和同步器布局，以及
sys_clk到FSPI数据输出的时延；不要对所有内部路径一律false_path。
此轮未做PDS静态时序收敛和板级测量，1MHz也必须上板验证。

## 软核MMIO（对齐32位访问，数据低8位有效）

| 地址 | 访问 | 含义 |
|---|---|---|
| 0x00030300 | RW | CPU缓冲区索引，低11位，0..2047 |
| 0x00030304 | RW | 指定索引的数据字节；不自动递增 |
| 0x00030308 | R | bit0忙、bit1协议错误、bit2越界、bit3CPU访问被拒绝；bits15:4为上一帧完整字节数 |
| 0x0003030C | W | bits1..3写1清对应粘滞标志 |

RK片选有效时CPU不能读写数据：读返回0，写忽略，并置拒绝标志。
索引/状态可访问；不完整字节不写RAM，超2048写丢弃，超2048读返回FF，不回绕。
复位清状态、不初始化RAM；上电首次读之前必须先由CPU或RK写入有效数据。
CPU和RK必须在应用层交接所有权。单独轮询busy不能防止RK在两条CPU指令之间发起通信。
本例通过IIC命令/回复协调；同一时刻只允许一个RK进程控制通道。

## 最快上板回环

你已持有厂商工具时，按手册但降低频率：

    ./smdt_spi_rw -d /dev/spidev4.0 -s 1000000 -OH -m 3 -S 256 -c 1

总线4.0来自手册，需确认当前RK设备节点。不要照搬50MHz命令。
如果驱动支持标准Linux spidev四线接口，可在RK的 csrc/rk_fspi 目录：

    make
    ./rk_fspi_demo /dev/spidev4.0 256
    ./rk_fspi_demo /dev/spidev4.0 2048

WSL产物不能作为RK可执行文件；需板上编译或匹配的交叉工具链。
该测试会覆盖缓冲区，只能在软核不同时使用该缓冲区时运行。
标准工具以两个transfer组成单个message保持CS，命令和数据都为4线。
若RK厂商驱动不支持SPI_IOC_WR_MODE32/tx_nbits/rx_nbits，程序明确报错；
需使用厂商工具或拿到驱动源进一步对接，不能认定/dev/spidev命名就等于兼容。
参考Linux官方接口文档：https://docs.kernel.org/spi/spidev.html

## 软核产生数据的联调固件

已提供通过软核联合仿真的 firmware/fspi_service/ 镜像及 manifest.json。
需要重新编译时，在WSL工程目录执行：

    python3 scripts/build_firmware.py --app fspi_service --image-dir firmware/fspi_service

你在PDS中将ROM/RAM初始化分别指向 firmware/fspi_service/rom.hex 和 ram.hex，
重新生成已有存储IP后再编译；不要选 ram_bytes.hex。此步仍由你操作。
固件不抢占FSPI，自身只响应IIC参数命令，回复通过原IIC recv逐字节读取：

- 启动回复：52 00 01 00 00（容量示例256字节）。先消费这5字节。
- IIC set 0x0000005a：软核写256字节 pattern[i]=i XOR 0x5a；
  IIC回复50 00 01 00 00后，RK才执行FSPI 0x80读256字节。
- RK通过FSPI写256字节后再IIC set 0x80000000：软核计算字节和；
  回复43加4字节小端校验和。写入0..255时和为32640，即43 80 7f 00 00。
- E0加4字节错误码：访问忙/拒绝等，不应在错误后盲目重试部分写入。

rk_fspi_read/write可用于上述业务读写，rk_fspi_demo是独立回环，不会保留CPU模式数据。
回复成功后数据长度/所有权由主机控制，不是自动消息队列，也不是视频帧缓存。

## 验证命令

    python3 scripts/check_fspi.py
    python3 scripts/check_sim.py --test TB_cpu_fspi
    python3 scripts/check_sim.py --test TB_cpu_iic
    make -C csrc/rk_fspi all test

行为仿真不等于板级时序/电平验证。原例程及PCIe IP完全未改动。
