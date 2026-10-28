# PG2L100H：Acore / EVOLVE5 与 CoreMark

当前分支为 `ziguang_rv32i`。目标沿用已经确认的 RK3568_MES2L100H：
**Logos2 / PG2L100H / FBG484 / -6，25 MHz，PDS 2022.2-SP6.1**。

## 选择内核

| 项目 | Acore 单发射（默认） | EVOLVE5 可选双发射 |
|---|---|---|
| 可编辑工程 | `rv32I.pds` | `cores/evolve5/pds/evolve5.pds` |
| 一键构建 | `scripts/build_fpga.ps1` | `scripts/build_evolve5.ps1` |
| 下载文件 | `download/coremark_single_25mhz.sbit` | `download/coremark_evolve5_25mhz.sbit` |
| RTL | `rtl/` | `cores/evolve5/rtl/`、`fpga/` |
| 程序镜像 | `firmware/rom.hex`、`ram.hex` | `firmware/evolve5_rom.hex`、`evolve5_ram.hex` |
| ROM / RAM | 32 KiB / 64 KiB | 32 KiB / 32 KiB |
| 默认迭代数 | 1000 | 2048 |

单发射的独立 Git 基线为 `e20bb3cae859de74291d5222d49fac3062fb8368`。
EVOLVE5 是另一套可选核，不是把你的 `Acore.v` 改成双发射；两套工程、IP、镜像和输出相互隔离。
GUI 工程位于不同目录，避免同名顶层的中间文件互相覆盖；双发射 GUI 工作文件由 `.gitignore` 单独排除。
均按 RV32I+Zmmul 编译，使用硬件乘法和软件除法。详细适配与限制见 [EVOLVE5 说明](cores/evolve5/README.md)。

```powershell
./scripts/build_evolve5.ps1 -Python python -ModelsimBin 'C:\diskE\modelsim\win64'
```

双发射版沿用相同的五个板级引脚与串口参数，LED3 仍只表示程序结束，LED4 表示异常。
不要同时把两套 `board_top`、两套存储器模型或两套核的源文件加入一个 PDS 工程。
以下章节描述默认 Acore 工程；双发射版有不同的 RAM/MMIO 地址。

## 本机离线验证结果

两版均为 GCC 10.2.0、O2、2000-byte 工作集、25 MHz、硬件乘法与软件除法。

| 项目 | Acore 单发射 | EVOLVE5 双发射 + Cache |
|---|---:|---:|
| performance 迭代数 | 1000 | 2048 |
| 目标计时 / 秒 | 15.132597 | 20.385616 |
| CoreMark/MHz（仿真） | 2.643300 | 4.018520 |
| 计时窗口 IPC | 未测 | 1.245147 |
| LUT / FF | 2812 / 4520 | 9960 / 7834 |
| APM / DRM36K | 4 / 24 | 4 / 16 |
| 25 MHz slow/fast setup/hold | 全部通过 | 全部通过 |

两组标准 CRC、长跑及最终独立 STA 均通过；证据见 `reports/coremark/`。
上述约 52% 提升是两套核与存储层次的整体仿真对比，不是同一内核只开关双发射的对比。
**两套新位流均尚未进行实板验收，不能把上述数字当作实板正式成绩。**

## 本次移植范围

CPU 基于 `origin/main` 的 `9bd2479b0ce167a77bfa4ca22e1969984f06a236`，导入到 `rtl/`。
保留五级单发射、分支预测、CSR、定时器中断进入和 MRET；本板级版本将 `timer_irq` 接零。
默认硬件乘法、软件除法，即 RV32I + Zmmul；`ENABLE_DIV=0`。
处理器的 33×33 有符号乘法使用官方 Simple Multiplier IP，三拍，四个 Logos2 APM。
ROM/RAM 同样使用官方 IP，不把仿真数组加入 PDS。

DDR、AI/YOLO、视频和 IIC 不接入当前上板顶层。原有 `rtl/rk_iic`、`csrc/rk_iic`、
相关文档及仿真文件保留；不要把原 `TB_board_iic` 当作当前顶层的测试。
`origin/main` 的 AI/DDR 软件和 RTL 在原分支中保留，本次没有合并或改写它们。

## 下载及上板现象

- 当前可编辑入口：`rv32I.pds`；批处理工程：`build/pds/rv32I.pds`。
- 审计通过的下载文件：`download/coremark_single_25mhz.sbit`。
- 使用 3.3 V USB-TTL，RX 接扩展口第 3 脚（FPGA TX，AB21），并接 GND。
- 终端为 **115200 / 8N1 / 无流控**。板载 CH340 连接 RK3568，不是本软核的发送口。
- 先打开终端再下载；也可按下并释放 KEY0，约 10 ms 后重新启动。

默认 firmware 是 CoreMark performance，2000 字节工作集，单上下文，1000 次迭代。
启动先打印 `Acore single issue / RV32I+Zmmul / 25000000 Hz / UART 115200`，
等待运算后打印计时、编译参数和 CRC，最后为 `COREMARK DONE`。
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
| ROM/RAM 镜像 | `firmware/rom.hex`、`ram.hex`，每行一个小端 32-bit 字 |
| 编译结果 | `build/firmware/coremark-<mode>-<iterations>/`，含 ELF、map、反汇编和清单 |

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

`uart_tx.v` 原本就存在；本次补齐 CoreMark 的轮询发送适配和 CR/LF，不依赖 TB 的 0x30008 字符口。
软件浮点和软件除法来自 RV32I 的 libgcc，不要求 F/D 或硬件除法器。

## 构建与验证

Windows 需要 Python、PDS 和 ModelSim 及各自有效许可证；交叉编译和快速仿真使用 WSL Ubuntu-22.04。
只运行 Windows 工程目录下的脚本，不读取或修改原 `~/mycore` 源码。
WSL 需要 `riscv64-unknown-elf-gcc`、G++、make、Icarus 和 Verilator。
GCC 10 使用 `-march=rv32im -mno-div`，显式链接 RV32I libgcc，并检查最终 ELF 不含 DIV/REM。

```powershell
./scripts/build_fpga.ps1 -Python python -ModelsimBin 'C:\diskE\modelsim\win64'
./scripts/build_fpga.ps1 -Application selftest
```

默认流程先用官方 ROM/RAM/乘法 IP 分别验证 performance/validation 单次迭代 CRC，
然后构建最终 1000 次固件，用 Verilator 检查真实 UART 比特流及至少十秒的目标计时，
再生成最终 IP、全地址初值遍历、71 项 RAM 检查和乘法专项，最后完成 PDS 全流程及审计。
单次短仿真里的十秒警告是预期的，不是正式成绩；最终固件不可忽略此警告。
最终长跑使用行为存储器/乘法模型；短跑已与官方 IP 的 CRC、周期和 UART 输出交叉验证。

本机缺少系统 Verilator 时，可在 WSL 中执行以下命令，仅解压到忽略目录，不安装到系统：

```bash
mkdir -p build/tools && cd build/tools
apt-get download verilator=4.038-1
dpkg-deb -x verilator_4.038-1_amd64.deb verilator-4.038
```

也可直接使用 PATH 中的 Verilator。详细证据见 `reports/coremark/` 和 `reports/migration.json`；
`scripts/test_interrupt.py` 回归 CSR、完整 GPR 保存/恢复、分支、访存、乘除等待期间的中断。
`scripts/check_sim.py` 使用行为模型进行基础回归；`scripts/check_modelsim.py --tests TB_coremark`
运行当前固件的官方 IP 测试（1000 次固件用 ModelSim 会很慢）。

## Git 与多人协作

提交 RTL、board 约束、脚本、C/汇编/链接脚本、CoreMark 源码和许可证、IP IDF/HDL/INIT 数据、
固件 hex 和验证报告。忽略 build、实现中间文件、下载位流、仿真波形、缓存及个人日志。
`.gitattributes` 统一文本 LF；批处理为 CRLF，二进制不作行尾转换。
不要提交许可证、个人绝对路径配置或编译器安装包；发布位流可用 Release/团队网盘另行分发。

IP IDF 的 INIT_FILE 是本机绝对路径，换目录后先运行 `prepare_ips.py` 再构建；
PDS 版本保持一致，同步 IP 参数改动时避免多人同时重新生成同一个 IP。
根 PDS 由 `export_project.py` 从原生工程导出并重新加载验证，不手写简化格式。
GUI 会更新 PDS 元数据，提交前检查是否只有时间戳和状态抖动。
`legacy/rv32I.pds` 是早期错误器件配置的历史参考，不是当前工程入口。
