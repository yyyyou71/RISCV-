# RV32I：PG2L100H FPGA 移植

DDR3 后续开发的独立行为模型、Linux 仿真命令与接口分析见 [DDR3 使用报告](docs/ddr3_usage_report.md)。当前 CPU RAM 接口保持原实现；该模型仅用于仿真，不加入 PDS 综合源文件。

本目录在 WSL `~/mycore/vsrc` 源码基础上建立 Windows 移植副本。目标板卡按用户确认采用桌面 `rv32i_optimized` 的 RK3568_MES2L100H 配置：**Logos2 / PG2L100H / FBG484 / -6，25 MHz**。WSL 原工程未修改。

第一阶段使用串口和 RAM 自检固件。PDS 实现与仿真结果保存在 `reports/migration.json`；实物上板验收仍需通过下述串口输出确认。

## 相对 WSL 源码的改动

本次导入基线为 WSL `~/mycore` 的提交 `f535e1ba6439cc5105935f210463b816ccec200e`。2026-10-22 逐文件对照：原有 16 个 RTL 文件中，11 个与 `rtl/` 中的副本内容相同，5 个存在下列改动。WSL 工作区保持干净。

| 原文件 / 当前文件 | 本次改动 |
|---|---|
| `ROM_core.v` / `rtl/ROM_core.v` | 将行为数组替换为 `pango_rom` IP 适配层，保留同步读和地址保持接口 |
| `memory_core.v` / `rtl/memory_core.v` | 将行为数组替换为 `pango_ram` IP 适配层；复位时禁止写入，B 口写使能关闭 |
| `soc.v` / `rtl/soc.v` | 增加 25 MHz 时钟、115200 波特率参数并传递给外设，引出两位 GPIO |
| `peripheral_bus.v` / `rtl/peripheral_bus.v` | 增加两位 GPIO 寄存器和 32-bit 周期计数器，保留原 UART 寄存器接口 |
| `branch_predictor.v` / `rtl/branch_predictor.v` | 将 `i++` 改成显式加法并重命名循环变量，以兼容 PDS Verilog-2001；预测算法保持原实现 |

`Acore.v`、`ALU.v`、`GPR_matrix.v`、`MuxKeyInternal.v`、`PC.v`、`ROM.v`、`Reg.v`、`decoder.v`、`hazard_detection_unit.v`、`memory.v` 和 `uart_tx.v` 的内容相同。流水线、译码、运算、前递及停顿/冲刷逻辑沿用原工程。

另外新增了板级顶层、按键复位电路、引脚/时序约束、自检 C 程序、启动代码、链接脚本，以及固件构建、IP 生成、仿真、PDS 实现和工程入口验证脚本。原 ROM/RAM 行为模型保存在 `sim/models/`，用于不依赖紫光 IP 的仿真；硬件工程使用新的 `ipcore/pango_rom/` 和 `ipcore/pango_ram/`。原来的 IP 目录与 `legacy/rv32I.pds` 保留作参考。

## 上板操作

1. 在 PDS 配置工具中选择 `download/selftest_25mhz.sbit`，下载至 FPGA 的 SRAM。
2. USB-TTL 的 RX 接 FPGA 扩展口第 3 脚（FPGA TX，AB21），并共地；使用 3.3 V TTL 电平。当前设计只有串口发送，无需连接 USB-TTL TX。
3. 串口设置 **115200、8 数据位、无校验、1 停止位**，关闭硬件流控。板载 CH340C 调试串口连接 RK3568；本软核使用上述扩展口。
4. 先打开串口终端，再下载程序；或者下载后按下并释放 KEY0，以重新打印自检结果。
5. 预期输出：

```text
RV32I FPGA 25MHz 115200
RAM INIT/BSS/BYTE/HALF/WORD PASS
SELFTEST PASS
```

通过后 LED3（`led0`，J16）亮，LED4（`led1`，M17）灭。程序自检失败或 CPU 访问未映射内存时 LED4 亮。KEY0（M15，低有效）释放稳定约 10 ms 后重新启动。

`rv32I.pds` 是可编辑工程入口；`build/pds/rv32I.pds` 是批处理生成并完成实现的工程。根目录入口从 PDS 自动生成的工程导出，保留完整的文件格式、时间戳、顶层及约束设置，并单独通过 PDS 加载和编译验证。若 PDS 已打开原工程，请关闭后重新打开以载入新的器件和源文件列表。原工程设置备份在 `legacy/rv32I.pds`。

## 存储器接入

| 项目 | 程序 ROM | 数据 RAM |
|---|---|---|
| CPU 地址范围 | 0x00000000–0x00007FFF | 0x00010000–0x0001FFFF |
| 物理容量 | 8192 × 32 bit，32 KiB | 16384 × 32 bit，64 KiB |
| 当前 IP | `ipcore/pango_rom` | `ipcore/pango_ram` |
| DRM36K 数量 | 8 | 16 |
| 读取延迟 | 同步读取一拍 | 同步读取一拍 |
| 额外输出寄存器 | 关闭 | A/B 均关闭 |
| 其他配置 | `ADDR_STROBE_EN=1`，高电平保持地址 | 真双口，4 个 8-bit 字节使能，A/B 均为 `TRANSPARENT_WRITE` |

原来的 IP 配置为 **Logos / PGL100H / FBG900**，因此保留原文件并另外生成正确系列的 IP。新 IP 命名为 `pango_rom` / `pango_ram`，避免与 CPU 的 `ROM` / `memory_core` 模块重名。

`rtl/ROM_core.v` 和 `rtl/memory_core.v` 是硬件适配层。RAM 当前只使用 A 口，B 口地址和写数据固定为零、写使能及字节使能为零，与 A 口使用同一时钟。后续可在适配层引出 B 口。适配层在复位时禁止 A 口写入；复位不擦除 RAM 内容。

`TRANSPARENT_WRITE` 在写入当拍返回新值；未使能的字节保持原值。CPU 外层仍只发出一个字地址，当前接口不支持同一拍访问两个不同的 RAM 字。保留 IP 的 B 口并不会自动增加 CPU 的并行访存能力。

RAM 需要硬件初值：现有 C 程序的常量和初始化数据放在 RAM 中，不能只初始化 ROM。`firmware/rom.hex` 和 `firmware/ram.hex` 均为**每行一个 32-bit 十六进制字**，字节按小端排列；ROM 未用部分填 NOP，RAM 未用部分填零。`firmware/start.S` 每次启动清 BSS 并设置栈，按键复位不会恢复程序修改过的 `.data`。

## 时钟、外设与约束

板级仿真为 ``always #20 sys_clk = ~sys_clk``（`timescale 1ns/1ps`），对应 25 MHz。原 Linux testbench 的 `#10` 对应 50 MHz；纯功能通过不能证明板上 50 MHz 时序或串口参数正确。新 `soc` 将时钟与波特率参数传递给外设，UART 分频为 217 个时钟/bit，约 115207 bit/s。

| 地址 | 用途 |
|---|---|
| 0x00030100 | UART TX，32-bit 写，最低字节为发送字符 |
| 0x00030104 | UART STATUS，bit0=1 表示可发送 |
| 0x00030108 | 两位 GPIO，可读写，连接 LED3/LED4 |
| 0x0003000C | 只读 32-bit CPU 周期计数器 |
| 0x00030000 | 程序退出标记，仿真检查使用，硬件忽略 |

引脚和电平来自用户指定的桌面参考工程：V4/1.5V 时钟、M15/1.8V 按键、J16/M17/1.8V LED、AB21/3.3V UART。`board/timing.fdc` 约束为 40 ns、0.2 ns 不确定度。按键输入和异步 UART/LED 输出设置时序例外，内部 CPU、UART 分频器和存储器路径继续检查。PDS 对这些异步端口的 IO delay 提示需结合时序例外理解。

## 重新构建

在工程目录下运行 PowerShell：

```powershell
./scripts/build_fpga.ps1
```

脚本复用 WSL 的 `riscv64-unknown-elf-*` 工具链，按 `-march=rv32i -mabi=ilp32` 编译；依次生成固件镜像、重新生成两个官方 IP、运行 ModelSim 检查、执行 PDS 全流程、审计时序和复位初值，最后生成下载文件。Python、PDS 安装位置、WSL 发行版可通过脚本参数指定。许可证沿用 Windows 用户环境中的 `PANGO_LICENSE_FILE` / `MGLS_LICENSE_FILE`。

修改 C 程序后必须重新生成 IP：PDS 的初始化数据已转成 IP RTL 中的 `INIT_*` 参数，仅修改 hex 文件并不会更新旧比特流。

独立检查：

```powershell
python scripts/check_modelsim.py
python scripts/audit_build.py
python scripts/export_project.py
```

ModelSim 使用未经修改的 PDS 官方 IP 和 `GTP_DRM36K_E1` 仿真模型，检查全部 ROM/RAM 初值、ROM 地址保持、71 项 RAM 检查、字节/半字扩展、完整 115200 UART 输出、上电启动与按键重启。厂商 ROM 模板中未选中的地址宽度分支会产生 ModelSim 越界提示；完整地址遍历与串口测试均检查实际选中的配置。保留这些提示，没有修改厂商生成文件。

Linux 行为模型回归可运行 `python3 scripts/check_sim.py`，使用 `sim/models`，无需紫光 IP。硬件工程只加入 `rtl`、`board` 和两个新 IP；不要同时把 `sim/models` 加入综合源文件。原分支预测器中的 `i++` 已等价改为 Verilog-2001 的显式加法，以适配 PDS ADS。

## CoreMark 后续

先完成上述实物串口验收，再切换 CoreMark 固件。现有 WSL CoreMark 的打印依赖 TB 的 `0x00030008`，需要改为轮询硬件 UART STATUS 后写 TXDATA；计时地址 `0x0003000C` 已在硬件实现。编译时需设置 `CPU_CLOCK_HZ=25000000`，重新生成 ROM 和 RAM IP。

赛题一要求 CoreMark 测量时间不少于 10 秒，并提供资源、时序及流水线分析。32-bit 周期计数器在 25 MHz 下约 171.8 秒回绕，测量区间应小于一个回绕周期。当前自检通过不代表已取得 CoreMark 实物成绩。
