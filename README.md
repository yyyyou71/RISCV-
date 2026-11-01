# PG2L100H：Acore 双发射、HDMI / PCIe / DDR 与 AI 移植

当前分支为 `ziguang_rv32i`。目标沿用已经确认的 RK3568_MES2L100H：
**Logos2 / PG2L100H / FBG484 / -6，25 MHz，PDS 2022.2-SP6.1**。

2026-11-01：唯一根工程 `rv32I.pds`、顶层 `acore_dual_top` 已接入桌面 `ziguang-fpga2`
的 HDMI / PCIe / DDR，保留自己的 Acore 双发射；AI 已在活动顶层启用，控制/文本使用纯 SPI，板级 UART 已移除。
RK 通信用的 IIC（`u_rk_iic`、P19/R19、`0x30400` 邮箱/FIFO）已删除；
HDMI 芯片配置 IIC（`hd_scl=AA21`、`hd_sda=AA20`）继续保留。
当前默认 ROM/RAM 初值为 `firmware/video_diagnostic/`，厂商 IP 内嵌数据已同步更新。
CPU 按需抓取同帧原图和 96×96 张量，支持 SPI 整网模型加载、99 任务及检测结果，
新增前 16 框硬件叠加与受控 PCIe 发送。HDMI 未检出问题、RK 实板闭环和新版本最终时序仍待验证。

最新设计/寄存器/验证边界见 [P4 同帧画框与发送](docs/video_present_p4.md)，
模型服务见 [P3b 说明](docs/ai_network_p3b.md)，移植来源见 [M2 说明](docs/video_integration_m2.md)。
资源/时序看本次实现后的 `place_route/acore_dual_top.prr`、`place_route/acore_dual_top.rtr`，请核对报告时间。

下文保留 **M2 以前的 CPU / CoreMark 基线记录**。其中 UART、CPU-only 顶层、旧一键构建和部署步骤
不适用于当前 HDMI 系统；历史一键脚本已加保护，避免覆盖根工程。

## 历史 CPU / CoreMark 工程与构建

唯一维护的 PDS 工程入口是根目录 `rv32I.pds`，当前顶层为 `acore_dual_top`，运行 Acore 双发射 CoreMark。
2026-10-29 已恢复双发射入口，并保留合并后的 IIC FIFO；IIC CPU MMIO 改为
`0x30400`，从机地址仍为 `0x66`。本轮检查和后续 AI 接入方案见
[板级集成计划](docs/ai_board_integration_plan.md)，通信接口见 [RK 通道](docs/rk_cpu_link.md)。
DDR 块窗口、W8A16 五类算子及 CPU 调度代码已作为可选功能移植，单双发射短回归通过；
当前板级构建仍关闭 DDR/AI，接线和厂商 AI IP 尚待完成。见 [M1 移植说明](docs/ai_port_m1.md)。
后续模型加载/控制/结果通道已决定改为 SPI；本阶段按用户要求保留现有 IIC，暂不实现 SPI。
默认 `build_fpga.ps1` 构建双发射并更新这个根工程。单发射保留作回归和 Git 历史基线，
只有显式使用 `-Core single` 构建时才将同一个根工程切换为单发射。
PDS 在 `build/`、`compile/` 下自动产生的内部 `.pds` 属于忽略的中间文件，不是另一个维护入口。

| 项目 | Acore 单发射基线 | Acore 顺序双发射（当前默认） |
|---|---|---|
| 可编辑工程 | 显式切换构建后复用 `rv32I.pds` | 根目录 `rv32I.pds` |
| 一键构建 | `scripts/build_fpga.ps1 -Core single` | `scripts/build_fpga.ps1` |
| 下载文件 | `download/coremark_single_25mhz.sbit` | `download/coremark_acore_dual_25mhz.sbit` |
| RTL | `rtl/`，`ENABLE_DUAL=0` | 同一套 `rtl/`，`ENABLE_DUAL=1` |
| 程序镜像 | `firmware/rom.hex`、`ram.hex` | `firmware/acore_dual_rom.hex`、`acore_dual_ram.hex` |
| ROM / RAM | 32 KiB / 64 KiB | 32 KiB / 64 KiB |
| 迭代数 | 历史基线 1000 | 当前默认 2700（约30秒） |

单发射的独立 Git 基线为 `e20bb3cae859de74291d5222d49fac3062fb8368`。
双发射直接扩展 `rtl/Acore.v`，复用原有译码器、ALU、CSR、分支预测和多周期乘法单元。
新增第二个整数执行槽、四读两写寄存器堆、跨槽前递和八项取指队列；不使用 Cache。
两个配置共用根工程入口；存储器 IP、镜像和构建输出相互隔离，CPU 和 MMIO 地址保持一致。
均按 RV32I+Zmmul 编译，使用硬件乘法和软件除法。
详细设计、发射限制与验证方法见 [Acore 双发射设计说明](docs/acore_dual.md)。

```powershell
./scripts/build_fpga.ps1 -Python python -ModelsimBin 'C:\diskE\modelsim\win64'
```

双发射版保留原时钟、按键、两只 LED 和串口，并增加 IIC SCL/SDA；LED3 仍只表示程序结束，LED4 表示异常。
PDS 顶层分别为 `board_top` 和 `acore_dual_top`；仿真行为模型不加入硬件工程。
以下章节中的板卡、外设和地址说明适用于两个版本。

## 本机离线验证

两版均为 GCC 10.2.0、O2、2000-byte 工作集、25 MHz、硬件乘法与软件除法。
验证数据见 `reports/coremark/`；双发射逐指令对比、中断与实现审计见 `reports/acore_dual/`。
历史单发射基线为 2.643300 CoreMark/MHz（1000 次仿真）。
用户已报告优化 RTL 的 1000 次 O2 实板结果：281873350 周期、11.274934 秒，
88.692315 CoreMark，即 3.547692607 CoreMark/MHz，CRC 正确。
相同 RTL 上一次完成的实现为 6958 LUT / 5558 FF / 4 APM / 24 DRM36K，四角 setup/hold 通过；
完整原始报告在 `reports/acore_dual/resources.prr` 与 `timing.rtr`。
本次交付最终改为 O2、2700 次和精简 UART，初值已更新，按用户要求留待用户重新编译 Verilog 和烧录。
`reports/acore_dual/implementation.json` 标明这两种状态；不得把上一次资源快照当作最终固件已重新实现的证明。

## 本次移植范围

CPU 基于 `origin/main` 的 `9bd2479b0ce167a77bfa4ca22e1969984f06a236`，导入到 `rtl/`。
保留原五级主流水线、分支预测、CSR、定时器中断进入和 MRET；可选受限顺序双发射。
本板级版本将 `timer_irq` 接零；内核接口及仿真仍支持中断。
默认硬件乘法、软件除法，即 RV32I + Zmmul；`ENABLE_DIV=0`。
处理器的 33×33 有符号乘法使用官方 Simple Multiplier IP，三拍，四个 Logos2 APM。
ROM/RAM 同样使用官方 IP，不把仿真数组加入 PDS。

历史 IIC 通道现已删除；当前 RK 控制、日志、权重和检测结果均通过纯 SPI。
旧 `0x30400–0x30414` 地址不再实现；HDMI 配置 IIC 独立保留。
DDR、AI/YOLO、HDMI、PCIe 尚未接入当前 PDS；PCIe 已有的 RTL/IP 文件仅为移植准备。
`origin/main` 的 DDR/AI 逻辑现已选择性移入 `rtl/`、`csrc/software/`、`pc_ai/`，
通过 `soc.ENABLE_DDR/ENABLE_AI` 选择，默认关闭；没有改变 Acore 双发射实现。
HDMI 接入时将停用板级 UART：参考工程的 `r_in[7]` 和当前 `uart_tx` 都使用 AB21，不能共存。

## 下载及上板现象

- 当前可编辑入口：根目录 `rv32I.pds`，顶层 `acore_dual_top`。
- 在 PDS 中重新编译后，使用新生成的 `generate_bitstream/acore_dual_top.sbit`。
- 使用 3.3 V USB-TTL，RX 接扩展口第 3 脚（FPGA TX，AB21），并接 GND。
- 终端为 **115200 / 8N1 / 无流控**。板载 CH340 连接 RK3568，不是本软核的发送口。
- 先打开终端再下载；也可按下并释放 KEY0，约 10 ms 后重新启动。

默认 firmware 是 CoreMark performance，O2、2000 字节工作集、单上下文、2700 次迭代，预计约30.4秒。
启动先打印 `Acore in-order dual issue / RV32I+Zmmul / 25000000 Hz / UART 115200`，
等待运算后打印计时、CRC、CoreMark 和 CoreMark/MHz，最后为 `COREMARK DONE`。
不再打印冗长编译参数；编译信息仍保存在 firmware manifest 中。
正式有效运行必须有 `Correct operation validated.`，且 `Total time (secs)` 不小于 10。
performance 的 seed/list/matrix/state CRC 应为 `e9f5/e714/1fd7/8e3a`；
validation 为 `18f2/e3c1/0747/8d84`。

LED3（J16）表示程序已经结束，**不独立证明 CRC 正确**；LED4（M17）指示总线错误。
程序结束后不反复打印，也不闪灯。实板成绩以实际串口输出为准；离线验证不等于实板验收。

## 程序及存储器

| 内容 | 路径或配置 |
|---|---|
| 未修改的 CoreMark 算法源码 | `third_party/coremark/`，保留原许可证和 MD5 清单 |
| 裸机移植、发送函数、计时 | `csrc/coremark_port/` |
| 启动入口及链接脚本 | `csrc/coremark_port/start.S`、`link.ld` |
| 原 RAM/串口自检 C | `firmware/selftest.c`，仍可单独构建 |
| 程序 ROM | 0x00000000–0x00007FFF，32 KiB，8 个 DRM36K |
| 数据 RAM | 0x00010000–0x0001FFFF，64 KiB，16 个 DRM36K |
| 当前 ROM/RAM 镜像 | `firmware/acore_dual_rom.hex`、`acore_dual_ram.hex`，每行一个小端 32-bit 字 |
| 当前编译结果 | `build/firmware/acore-dual-coremark-<mode>-<iterations>/`，含 ELF、map、反汇编和清单 |

CPU 数据总线不能读指令 ROM，因此常量、字符串和初始化数据放 RAM。
IP 将镜像转换成 HDL 的 INIT 参数；改 C 或 hex 后必须重新生成 IP 再实现，不能只重新下载旧位流。
RAM 是真双口 `TRANSPARENT_WRITE`，当前 CPU 只用 A 口；同步读取一拍，额外输出寄存器关闭。
启动清 BSS，预留至少 8 KiB 栈；按键复位不擦除 RAM，也不自动还原任意已修改的 `.data`。

| MMIO 地址 | 功能 |
|---|---|
| 0x00030000 | 程序结束标记，供仿真判断退出 |
| 0x0003000C | 只读 32-bit 周期计数器，25 MHz 下约 171.8 秒回绕 |
| 0x00030100 | UART TXDATA，32-bit 写，低八位发送 |
| 0x00030104 | UART STATUS，bit0=1 可发送 |
| 0x00030108 | 两位 GPIO |
| 0x00030400–0x00030414 | IIC 发送 FIFO、参数、版本确认和溢出状态；从机地址仍为 0x66 |

预留 `0x30200` 给 AI、`0x30300` 给视频、`0x31000` 给 DDR 窗口，均尚未接入本分支顶层。

`uart_tx.v` 原本就存在；本次补齐 CoreMark 的轮询发送适配和 CR/LF，不依赖 TB 的 0x30008 字符口。
软件浮点和软件除法来自 RV32I 的 libgcc，不要求 F/D 或硬件除法器。

## 构建与验证

Windows 需要 Python、PDS 和 ModelSim 及各自有效许可证；交叉编译和快速仿真使用 WSL Ubuntu-22.04。
只运行 Windows 工程目录下的脚本，不读取或修改原 `~/mycore` 源码。
WSL 需要 `riscv64-unknown-elf-gcc`、G++、make、Icarus 和 Verilator。
GCC 10 使用 `-march=rv32im -mno-div`，显式链接 RV32I libgcc，并检查最终 ELF 不含 DIV/REM。

```powershell
./scripts/build_fpga.ps1 -Python python -ModelsimBin 'C:\diskE\modelsim\win64'
./scripts/build_fpga.ps1 -Core single -Application selftest
```

默认流程先用官方 ROM/RAM/乘法 IP 分别验证 performance/validation 单次迭代 CRC，
然后构建最终 2700 次固件，默认跳过长程仿真，留给实板运行，
再生成最终 IP、全地址初值遍历、字节写掩码检查和乘法专项，最后完成 PDS 全流程及审计。
单次短仿真里的十秒警告是预期的，不是正式成绩；最终固件不可忽略此警告。
只有显式传入 `-RunLongSimulation` 才运行长程仿真；本次未对最终2700次版本执行该步骤。
最终交付只更新了固件初值和根工程，后续 HDL 编译、布局布线及烧录由用户完成。

本机缺少系统 Verilator 时，可在 WSL 中执行以下命令，仅解压到忽略目录，不安装到系统：

```bash
mkdir -p build/tools && cd build/tools
apt-get download verilator=4.038-1
dpkg-deb -x verilator_4.038-1_amd64.deb verilator-4.038
```

也可直接使用 PATH 中的 Verilator。当前双发射证据见 `reports/coremark/` 和 `reports/acore_dual/`；
`scripts/test_interrupt.py` 回归 CSR、完整 GPR 保存/恢复、分支、访存、乘除等待期间的中断。
`scripts/check_sim.py` 使用行为模型进行基础回归；`scripts/check_modelsim.py --core acore_dual --tests TB_coremark`
运行当前固件的官方 IP 测试（1000 次固件用 ModelSim 会很慢）。

## Git 与多人协作

提交 RTL、board 约束、脚本、C/汇编/链接脚本、CoreMark 源码和许可证、IP IDF/HDL/INIT 数据、
固件 hex 和验证报告。忽略 build、实现中间文件、下载位流、仿真波形、缓存及个人日志。
`.gitattributes` 统一文本 LF；批处理为 CRLF，二进制不作行尾转换。
不要提交许可证、个人绝对路径配置或编译器安装包；发布位流可用 Release/团队网盘另行分发。

IP IDF 的 INIT_FILE 是本机绝对路径，换目录后先运行 `prepare_ips.py --core acore_dual` 再构建；
PDS 版本保持一致，同步 IP 参数改动时避免多人同时重新生成同一个 IP。
根 PDS 由 `export_project.py` 从原生工程导出并重新加载验证，不手写简化格式。
GUI 会更新 PDS 元数据，提交前检查是否只有时间戳和状态抖动。
其他历史工程入口已删除，需要查阅旧配置时使用 Git 历史。
