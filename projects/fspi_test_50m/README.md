# 原厂主机接口适配更新（SMDT_V3）

已对照用户提供的 smdt_fpga_fspi_demo/src/smdt_spi_rw.c 修正独立测试工具：
- 手册-OH设置CPOL|CPHA，即mode 3；-m 3单独表示四线协议。
- 写前设置mode 0x203，读前设置mode 0x803，不同时启用TX_QUAD与RX_QUAD。
- 每次SPI_IOC_MESSAGE(1)仅提交payload，len=N；不在用户态添加0x00/0x80命令。
- tx_nbits和rx_nbits均为4，与原厂例程一致。频率保持50MHz。

将rk_tool源码覆盖到RK后执行：

    make clean && make
    ./rk_fspi_demo /dev/spidev4.0 256

版本标识应为FSPI_TOOL_SMDT_V3，写/读returned均应为256（原工具为257）。
现有50MHz位流不变；追加TB_fspi_mode3.v验证idle-high、下降沿输出/上升沿采样，2KB/越界/中断恢复测试通过。
用户态原例程没有显式命令，但FPGA例程有命令解码；命令由驱动/控制器产生是推断，尚无驱动源码或波形验证。
本次未宣称板上通过。若V3仍失败，用用户提供bin/smdt_spi_rw按手册命令对照，不再猜测软件格式。
原厂工具即使比较出错也可能返回0，应看Error Rate是否0.00%，不能只看shell退出码。

---

# FSPI 50MHz 独立回环测试

本目录替代此前1MHz测试副本，匹配RK smdt_spi_controller驱动允许的原例程50MHz频率。
必须同时下载本目录新位流并重新编译本目录rk_tool。不要把50MHz工具配旧1MHz位流。

打开 fspi_test.pds，顶层 fspi_loopback_top；PG2L100H / FBG484 / -6。
25MHz sys_clk只用于复位和LED，收发逻辑直接由外部50MHz SPI时钟驱动。
保留原例程四线、mode 0、0x00写/0x80读、高半字节先传、无地址/无dummy、每帧从0开始。
2KB存储由RTL推断；没有手动生成或例化厂商PLL/RAM IP。软核、固件及主工程不修改。

引脚：sys_clk V4 1.5V SSTL15_I；key0_n M15、led0 J16、led1 M17为1.8V。
FSPI：SCK L19、CS L20、D0 N22、D1 M22、D2 M18、D3 L18，均LVCMOS18。
LED0心跳翻转，LED1见到CS活动后保持；以RK逐字节比较PASS为准。

下载 build/generate_bitstream/fspi_loopback_top.sbit，再将rk_tool复制到RK。
在RK的工具目录执行：

    make clean
    make
    ./rk_fspi_demo /dev/spidev4.0 256
    ./rk_fspi_demo /dev/spidev4.0 2048

新程序成功时明确输出 at 50 MHz。主机工具只允许50MHz，防止误配旧测试条件。
不要复制WSL生成的可执行文件到RK，只复制源码并在RK编译。
若再次出现1000000Hz，运行的仍是旧程序。若50MHz请求仍报EINVAL，需继续核对厂商驱动的四线分段传输支持。
有原厂smdt_spi_rw工具时，可按手册使用：

    ./smdt_spi_rw -d /dev/spidev4.0 -s 50000000 -OH -m 3 -S 256 -c 1

这里厂商工具-m 3表示四线宽度，不是SPI mode 3。

时序：约束SCK周期20ns、输入延迟0..5ns相对下降沿、RK接收建立预算3ns。
这些为工程预算，并非实测RK/板级参数；即使PDS通过仍需板上验证。
CS高期间允许无SCK；帧间CS高至少1us。复位解除后等待1us再开始命令。
无CPU访问；超2KB写丢弃、超2KB读FF、半字节中断不提交，CS拉高立即释放数据线。

行为测试：

    mkdir -p build
    iverilog -g2012 -s TB_fspi_loopback -o build/test.vvp TB_fspi_loopback.v fspi_loopback_top.v fspi_sck_slave.v board_reset.v
    vvp build/test.vvp

测试覆盖50MHz两轮2KB数据、越界、无空闲时钟的CS中断恢复、非法命令及复位。

## 本次验证结果

2026-10-30：PDS Compile/综合/布局布线/时序/位流生成通过，退出码0。
50MHz SPI慢角setup余量0.062ns、快角hold余量0.101ns；余量较小，尚未上板验证。
位流SHA256：a211ff4f46363ef43d43bc91e4f3c0484140963c49797c67b5ad38f5789d7fbb

## 上板读回不匹配排查

DIAG_V2显示ioctl返回字节数、错误总数和前32字节TX/RX。返回成功不证明物理总线波形正确。
如果程序频率已是50000000而读回00，先在相同50MHz位流上用手册的smdt_spi_rw命令对比。
旧DIAG_V2使用command/data两个transfer，已被上述SMDT_V3替代。
若厂商工具通过而helper失败，优先对照厂商应用/驱动源码；若都失败，再查实际位流、引脚及SCK/CS/DQ波形。
LED1只表明观察到CS活动，不证明命令或数据正确。
