# 主工程 FSPI 50 MHz 集成（2026-10-31）

## 当前状态与边界

主顶层 acore_dual_top 默认 ENABLE_FSPI=1，连接经过 board_top、soc、peripheral_bus。
使用已上板验证的 SCK 上升沿采样、下降沿输出方式；新增 CPU 与 SPI 间独立双时钟收发缓冲。
这次主工程改版仍需重新综合/布局布线、检查时序、生成并下载 bit；独立测试版的板级通过结果不能替代此验证。
没有改动现有软核、firmware 下任何文件、初始化镜像或厂商 IP；没有修改根 rv32I.pds。
SPI 模块原本已列入 PDS，所以不用另加源文件，也没有新建或手工例化厂商 IP。

重要：现有固件不会自动调用新接口。仅下载新硬件不能让旧回环命令自动通过。
生产版不是共享内存硬件回环：RK 写的是 RX RAM，RK 读的是 CPU 发布的 TX RAM。
旧 firmware/fspi_link.h、fspi_service 镜像不兼容 FSP2；保持原文件是为了不改变当前软核程序。
提供可选驱动 csrc/rk_fspi/fspi_v2.h，尚未接入或编译进现有固件。

## 物理接口

50 MHz、四线、mode 3（CPOL=1/CPHA=1），高半字节先传。
SCK=L19，CS=L20，DQ0=N22，DQ1=M22，DQ2=M18，DQ3=L18，均为 LVCMOS18/1.8V。
线上命令 00 为 RK 写入、80 为 RK 读取；无地址、无 dummy，1..2048 字节。
RK 的 SMDT 驱动接口沿用成功测试版本：mode=0x203 写、0x803 读，单个 payload-only transfer。
不要在用户数据前额外添加 00/80；这是特定 SMDT 驱动接口，不是所有 spidev 控制器通用协议。
帧间 CS 高电平至少 1us；CPU ARM/COMMIT 后至少 1us 才允许 RK 开始命令。
CPU 和 RK 必须通过应用控制通道（例如已有 IIC）协商方向、长度和就绪；本次没有改变 IIC 应用协议。

## CPU 寄存器

当前 acore_dual_top 基址 0x00030300：视频在独立平台中，soc 的 ENABLE_VIDEO 仍是 0。
只有 soc ENABLE_VIDEO=1 才重映射为 0x00030700。寄存器仅支持对齐 32 位访问。

| 偏移 | 名称 | 含义 |
|---|---|---|
| 00 | INDEX | RX 读、TX 写的字节索引，低 11 位有效，不自动递增 |
| 04 | DATA | 写低 8 位进入 TX RAM；读 RX RAM 的一个字节 |
| 08 | STATUS | bit0 活动/交接中；bit1 协议/短帧错误；bit2 超长；bit3 拒绝访问；bit15:4 最近帧完成的字节数（饱和 2048） |
| 0c | CLEAR | bit1/2/3 写 1 清对应错误；不会取消正在传输的缓冲区 |
| 10 | ARM_RX | 写预期长度 1..2048，释放上一包 RX 并允许 RK 写新包；读配置长度 |
| 14 | COMMIT_TX | 写长度 1..2048 发布 CPU 已填好的 TX 缓冲；读配置长度 |
| 18 | OWNERSHIP | bit0 RX_READY，bit1 TX_PENDING，bit2 RX_ARMED |
| 1c | ABI | 只读 0x46535032（FSP2） |

STATUS 忙置位时不要操作缓冲；各方向所有权也必须满足要求。
RX_READY 只有完整达到预期长度才置位；读取不会清除，就绪数据保持到下一次 ARM_RX。
TX_PENDING 置位后 CPU 数据写被拒绝，直到 RK 完整读取预期长度；避免半包被 CPU 覆盖。
读 RX 未就绪时返回 0 并置拒绝标志；RK 未经 ARM 写入会丢弃并报拒绝；无 TX_PENDING 时 RK 读取 FF。
ARM/COMMIT 的零长度、超过 2048、重复提交或忙时提交会被拒绝。

## 跨时钟与恢复

RX RAM 只由 SCK 域写、CPU 域同步读；TX RAM 只由 CPU 域写、SCK 域同步读。
每个 RAM 只有一个写时钟，不需要两时钟同时写同一数组。
请求/完成 toggle 经过两级同步；长度在所有权交接期间保持稳定。
命令的两个上升沿用于同步请求，数据阶段才使用所有权，因此不要求 CS 高时提供空闲时钟。
完成标志在最后一个数据上升沿产生并保持，SCK 停止后 CPU 仍能看到完成。
CS 异步重置帧状态、立即释放 DQ；错误摘要在 SCK 停止后保持，由 CPU 在同步 CS 高且等待四拍后采样。
时序约束给跨域路径设置了传播上限，不是对所有跨域数据一概 false path。

短帧/半字节中止不会完成所有权转移；原长度和缓冲锁仍保持。
双方确认事务状态后，可从索引 0 重新执行完整帧；驱动不自动重试。
目前没有软件取消挂起帧的寄存器；不再继续该事务时需要协调板级复位。
超长帧只保留/提供声明长度的数据，其余写入丢弃、读取 FF，并置超长标志。
全局复位清所有权和状态，不清 RAM；未发布的数据不会作为有效包输出。

## 后续板级测试

1. 在 PDS 重新编译当前主工程并运行实现/时序检查，生成新的主工程 bit。
2. 后续将可选 fspi_v2.h 接入应用（现有固件本次未改）。单 CPU 独占 INDEX/DATA，避免中断/另一核交错访问。
3. RK->CPU：CPU fspi_v2_arm_rx(N)，通过控制通道通知 RK；RK 执行 write N；CPU 等 STATUS bit0=0 且 RX_READY=1，然后 fspi_v2_receive。
4. CPU->RK：CPU fspi_v2_publish，通知 RK 长度和就绪；RK 执行 read N；CPU 等 TX_PENDING 清除。
5. 回环需 CPU 显式 receive 后 publish，确认 TX 就绪后 RK 再读，不能立即连续 write/read。
6. 验证 1、16、256、2048 字节，检查 CPU STATUS 错误位，再测试与 IIC/视频/DDR 同时工作。

RK 端复制 csrc/rk_fspi 的 Makefile、rk_fspi.c、rk_fspi.h、rk_fspi_demo.c 后：

    make clean
    make
    ./rk_fspi_demo /dev/spidev4.0 write 256
    ./rk_fspi_demo /dev/spidev4.0 read 256

以上两条数据命令必须分别满足 CPU ARM/COMMIT 前置条件；不可当成无需固件配合的回环脚本。
write 使用 (i*37)^0xa5 的测试字节，read 打印接收到的数据。
ioctl 返回完整长度只表示主控完成传输；SPI 无通用从机 ACK，不等于 CPU 收到了正确数据。

## 可重复验证

    python3 scripts/check_fspi.py
    python3 scripts/check_fspi_integration.py
    make -C csrc/rk_fspi clean all test

- 50MHz mode3 仿真覆盖 1/16/256/2048 双向传输、所有权、未提交访问、短帧重试、溢出、无空闲 SCK、活动复位。
- 视频模式 0x30700 地址隔离、CPU IIC MMIO 与现有 IIC 固件回归。
- RK mocked ioctl 检查 mode3、方向标志、payload-only、短传输、错误返回和不自动重试。
- 隔离副本 build/fspi_main_50m/main_check.pds 用于 PDS 检查，不覆盖根项目。
- PDS 单模块综合确认识别两个 2048x8 RAM，合计 1.0 DRM36K（两个半块），无锁存器。
- IO 延迟仍是测试版工程预算，尚未完成主工程布局布线后的时序签核或板级验证。


Final verification: full acore_dual_top PDS Compile and Synthesize passed. Whole-design resources: 19,088 LUTs, 19,648 registers, 72.5 DRM, zero latches.
Existing IP/input-constraint warnings remain. Place-and-route, routed timing signoff, new bitstream generation and hardware tests were not run.
See build/fspi_main_50m/verification.json. All 29 protected firmware/core/root-PDS files match their pre-edit hashes.
