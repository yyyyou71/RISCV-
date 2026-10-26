# 基于RV32I指令集的cpu设计


## 仿真环境：
主要使用iverilog仿真工具进行仿真，全平台通用。后续工程变大可以考虑使用verilator，不过这样就只支持linux平台了。
## 项目目录
/Iverilog： 存放使用iverilog工具进行仿真的TB文件。  
/vsrc： 存放处理器设计的源文件  
/csrc： 计划存放使用verilator工具进行仿真的TB文件，以及后续需要在设计的处理器上运行的测试程序  
/asm:   测试用的汇编  
/program:   需要加载的二进制程序 

## 外设地址
结束仿真：0x00030000
终端打印：0x00030004 0x00030008
串口：00030100-0104

## DDR 指定地址块搬运

新增独立模块 `vsrc/ddr_block_transfer.v`：通过命令指定字节地址、长度和读写方向，
支持 16～256 字节、16 字节对齐，内部处理紫光 x16 原生地址换算和跨列拆分。
写入前缓存整块数据，读取后通过可暂停的数据流输出；现已通过可选的 MMIO 窗口接入 CPU/SoC。
接口、完成状态和错误恢复见 [DDR 块搬运说明](docs/ddr_block_transfer.md)。

```bash
make test-ddr-block-transfer
```

回归使用 `vsrc/ddr3.sv` 行为模型，覆盖不连续地址、部分覆盖、跨列、停顿、复位和协议异常，
日志与向量保存在 `build/ddr_block_transfer/`。本模块尚未完成 PDS 综合及实板验证。

## CPU 访问 DDR 的外设窗口

`vsrc/ddr_cpu_window.v` 提供地址、长度、启动/状态寄存器和 256 字节窗口，
寄存器位于 `0x00031000`，数据窗口位于 `0x00031100`。
CPU 的默认频率参数为 25 MHz，与 DDR 用户时钟通过邮箱握手跨域。
使用时设置 `soc.ENABLE_DDR=1`，连接真实 DDR IP 的用户接口；默认关闭以保留原 UART 配置。

```bash
make test-ddr-cpu-window
```

CPU 裸机样例：`csrc/software/ddr_window_test.c`。
寄存器、接线、跨域约束和验证范围见 [CPU DDR 窗口说明](docs/ddr_cpu_window.md)。
目前完成行为仿真，尚未完成 PDS 综合、跨域物理时序检查和实板验证。

## 可配置单层整数卷积

`vsrc/conv2d_core.v` 支持运行时配置高宽、输入/输出通道、1×1/3×3 核、
步长与 padding。默认 W8A8，另验证 W8A16 和 W9A16 综合配置。
当前输出完整的卷积累加值，尚未接入模型量化、CPU 调度寄存器或 DDR 缓存。

```bash
make test-conv2d-core
```

[计算接口、数值范围及 DDR 数据流](docs/conv2d_core.md)说明了模型数据和运行时配置的区别。
本阶段完成独立数学对拍，不代表已运行完整检测模型或完成实板加速。

## Multiply-Adder 行为模型

`vsrc/multiply_adder.v` 按本地《简单乘法器.pdf》模拟 `a0*b0 ± a1*b1`，
支持静态加/减、0～5 级流水线和同步/异步复位。默认有符号 8×8、17 位输出、3 级、同步复位。
它没有反馈累加；并行卷积通路 `conv_mac_tile` 例化 4 个实例，并在外部累加部分和。

```bash
make test-multiply-adder
```

[IP 配置、替换步骤及下一阶段安排](docs/multiply_adder.md)说明支持范围及验证限制。
现有 DDR 卷积通路采用小块缓存、连续供数和 4×2 并行归约。

## 并行卷积与 DDR 单层闭环

`conv_mac_tile` 实际例化 4 个 `multiply_adder`，以 W8A8 的 4 输出通道×2 项归约连续计算。
`conv2d_ddr_engine` 使用小块输入/权重缓存和跨通道块部分和，通过现有搬运器完成整层读入、计算、写回。
SoC 设置 `ENABLE_DDR=1, ENABLE_AI=1` 后，CPU 可通过 `0x30200` 起的控制寄存器提交任务，
通过原 DDR 窗口装载和读回数据。默认关闭 AI，CPU 默认频率参数仍为 25 MHz。

```bash
make test-ai-accelerator
```

[数据布局、寄存器和验证说明](docs/conv2d_ddr_engine.md)。裸机样例为 `csrc/software/conv2d_ddr_test.c`。
已完成 CPU/DDR 行为仿真闭环，保留原始 INT64 输出，并新增逐通道重定标、可选 ReLU 和 HWC INT8 输出。
CPU 可让第二层直接读取第一层在 DDR 中的 INT8 特征图，无需搬运或重排；新增裸机样例为 `csrc/software/conv2d_chain_test.c`。
[数值规则、量化参数表和两层验证](docs/quantization_int8.md)。完整检测模型、SiLU 等其它算子、PDS 和实板验证尚未完成。

CPU 已支持从 DDR 任务表运行网络。`ai_runtime.c` 每次只缓存一条 64 字节任务，
PC 工具负责打包输入、权重、量化参数和静态张量地址；同一固件/RTL 可运行不同层数与通道数的网络。

```bash
make test-ai-tasks
python3 scripts/pack_ai_model.py examples/ai_tasks/two_layer.json \
  --output build/ai_example/model.bin --request build/ai_example/request.bin --reference
```

任务表格式、装载位置、错误报告与验收范围见 [DDR 任务表和 CPU 调度](docs/ai_task_runtime.md)。
SPI 装载/启动协商尚待接入，当前用测试平台预装载 DDR。

## CoreMark：Icarus 与 Verilator

```bash
make coremark                       # Icarus，默认每组种子运行 1 次迭代
make coremark-verilator             # Verilator，默认每组种子运行 100 次迭代
make coremark-verilator ITERATIONS=1  # 与 Icarus 的单次结果对比
make coremark-verilator ITERATIONS=600 MAX_CYCLES=1000000000
```

默认均运行 performance 和 validation 两组种子，可加 `COREMARK_MODE=performance`
只运行性能组。`ITERATIONS` 是算法迭代次数，`MAX_CYCLES` 是整个程序的周期上限。
32 位计数器要求周期上限小于 `2^32`。普通 C 程序的 `make build` / `make iv` 用法不变。

Verilator 路径复用 `Iverilog/TB_Acore.v`，通过 `--binary --timing` 自动生成 C++ 驱动，
保留时钟延迟、复位、MMIO 字符输出和周期计数。ROM/RAM 的 `initial` / `$readmemh`
直接支持，不需要改成手动 C++ 加载。两种后端都关闭波形输出并检查原版算法 CRC。
要求支持 `--binary --timing` 的 Verilator 5.x，以及支持 C++20 coroutine 的 C++ 编译器；
本机验证版本为 Verilator 5.052。

软件源文件列表在 `csrc/coremark_port/sources.mk`，构建和结果检查在 `scripts/coremark.py`。
Verilator 的产物在 `build/coremark/verilator/<模式>-<迭代次数>/`；Icarus 产物仍在
`build/coremark/<模式>-<迭代次数>/`。目录中包含 ELF、链接 map、反汇编、ROM/RAM 镜像、
`run.log` 和 `result.json`；Verilator 另有 `verilator-build.log` 与生成的 `obj_dir/`。

报告中的 `Total ticks` 是目标 CPU 计时周期；目标频率为 50 MHz，
`simulation_wall_seconds` 则是电脑实际执行仿真的秒数（不含编译），二者不能混用。
当前 `HAS_FLOAT=1`，原版报告的秒数和 `Iterations/Sec` 显示小数。
通过 `ISA=rv32i` 可保留 RV32I/ILP32 编译；浮点计算由 `libgcc` 用整数指令实现，不要求 F/D 扩展。
移植层的 `cvt.c` 负责浮点转字符串，并在本地实现小数/整数拆分，避免依赖 libc/libm。
脚本会核对 CPU 打印的小数与原始周期计算结果是否一致；`result.json` 保存未按六位小数截断的结果。
短于 10 秒的目标运行会保留原版 CoreMark 的时长错误，仅标为短运行估算。
增加迭代次数后，脚本仍独立检查 CRC，并按原始周期计算性能。
这属于当前 RTL/存储器模型的仿真结果，50 MHz 是设定的目标频率，未证明 FPGA 时序收敛。

## 乘法扩展：RV32I + Zmmul

支持 `MUL`（低 32 位）、`MULH`（有符号×有符号的高 32 位）、
`MULHSU`（有符号 rs1×无符号 rs2 的高 32 位）、`MULHU`（无符号×无符号的高 32 位）。
这是 Zmmul 乘法扩展。开启下文的 `ENABLE_DIV` 后，另支持 M 扩展中的四条除法/余数指令。

新增 `vsrc/multiplier_core.v` 根据本目录《简单乘法器.pdf》模拟紫光 Simple Multiplier
的 `a/b/clk/rst/ce/p` 接口。使用固定有符号 33×33 位乘法器，输出 66 位；
对原来的 32 位操作数选择符号扩展或补 0，让四条指令共用一个 IP。
`rst` 高有效同步复位，`ce=0` 时所有寄存器保持。模型只复现周期行为，
不模拟 APM 内部结构，也不能据此判断 FPGA 资源占用和最高频率。

`vsrc/multiply_unit.v` 负责启动、等待和结果选择。默认使用手册表 2-17 的 3 级配置，
对应 XYREG、MREG、PREG；模型支持 1～5 级。3 个使能上升沿后 IP 结果有效，
第 4 个沿进入原有 EX/MEM 寄存器，因此乘法在 EX 中占用 4 拍、增加 3 拍停顿。
此实现一次只处理一条乘法，即使 IP 内部有流水级，也不每拍发起新的乘法。

`vsrc/decoder.v` 增加四条指令的译码；`vsrc/Acore.v` 增加乘法单元和结果选择。
等待期间保持 PC、IF/ID、ID/EX，向 EX/MEM 注入空泡，年老指令继续完成访存和写回。
load-use 解除后才启动 IP，以便正确采样前递数据；结果沿用已有 ALU 前递和写回通道。
原有 `Iverilog/TB_Acore.v` 仅增加级数参数，仍负责 Acore 的系统仿真。

编译时需要启用乘法，否则原有 RV32I 程序仍使用软件乘法：

```bash
make coremark-verilator ISA=rv32i_zmmul ITERATIONS=100
make coremark ISA=rv32i_zmmul ITERATIONS=1
make build PROG=sort ISA=rv32i_zmmul
make iv PROG=sort
make test-multiply
```

通过 Makefile 构建时，默认 `ISA` 由下文的 `ENABLE_DIV` 开关决定。
仍可显式传入 `ISA=rv32i` 运行纯 RV32I 程序。本机 GCC 10 不识别 `-march=rv32i_zmmul`，
所以 `build.sh` 和 CoreMark 脚本将此选项转换成 `-march=rv32im -mno-div`，
并显式链接 RV32I 的 `libgcc`，让除法继续走软件实现。
CoreMark 构建还会检查最终反汇编，确认已生成乘法且没有硬件除法/余数指令。
Zmmul 的结果目录是 `build/coremark/rv32i_zmmul/`，与 RV32I 基线分开保存。

`make test-multiply` 的 Python 脚本只负责生成数据、调用仿真和检查输出。
它先运行 `TB_multiplier.v` 检查 IP 的延迟、使能、复位和算术边界，
再复用 `TB_Acore.v` 运行乘法程序，核对宿主机 Python 整数计算的参考结果。
覆盖连续乘法、源/目的寄存器重叠、load-use、乘法结果到算术/访存/分支的前递、
错误路径冲刷和 x0。1～5 级配置均测试，日志和程序保存在 `build/multiply/`。
仿真源文件只包含 Acore 及其依赖，不包含 SoC 和外设顶层。

替换为真实紫光 IP 时，在 PDS 中生成名为 `pango_multiplier_ip` 的 Simple Multiplier：

| 配置项 | 配置值 |
| --- | --- |
| Port A / Port B | Signed，Width=33 |
| Port P | 66 位，完整乘积 |
| Pipeline Stages | 3，与 `Acore.MUL_PIPE_STAGES` 一致 |
| Async Reset | 不勾选，即高有效同步复位 |
| Advanced Mode / Optimal Timing | 均关闭 |
| ce | 高有效寄存器使能 |

把生成的 IP 及其依赖加入 PDS 工程，并定义 `PANGO_MULTIPLIER_IP` 宏，
`multiply_unit.v` 就会例化真实 IP；不定义时使用行为模型。
真实 IP 的延迟必须与参数一致，上板前仍需用 PDS 的 IP 仿真和静态时序分析确认。

本次 Verilator 回归使用每组 100 次迭代，结果如下，两种版本均通过两组 CRC：

| 种子组 | RV32I 周期 | 3 级硬件乘法周期 | 加速比 |
| --- | ---: | ---: | ---: |
| performance | 89,781,321 | 37,832,677 | 2.37 倍 |
| validation | 95,763,970 | 37,929,100 | 2.52 倍 |

性能组短运行估算从 1.113817 提升到 2.643218 CoreMark/MHz。
这些是 CoreMark 计时窗口内的目标 CPU 周期，两组均不足 10 秒，不是正式成绩。
以上为首次接入乘法器时的对比；可选除法器的独立结果见下一节。

## 可选除法器：完整 RV32IM

`vsrc/divider_core.v` 实现 32 位无符号恢复余数除法，每拍用减法器生成一位商，
固定迭代 32 拍，不使用综合工具的 `/`、`%` 或厂商 IP。
`vsrc/divide_unit.v` 完成输入绝对值、输出符号修正以及商/余数选择，支持
`DIV`、`DIVU`、`REM`、`REMU`。有符号商向零截断，非零余数与被除数同号。
除零返回全 1 的商和原被除数作为余数；`INT_MIN / -1` 返回 `INT_MIN` 和余数 0。

一次启动占 1 拍，迭代占 32 拍，结果接收占 1 拍，因此除法指令占用 EX 共 34 拍，
增加 33 拍停顿。期间前级保持、后级排空，数据从原有前递通道采样，结果复用 ALU 写回。
当前一次处理一条除法，连续的 DIV 和 REM 分别计算，不进行商/余数指令合并。

总开关在 `Acore` 的参数中，默认开启：

```verilog
parameter integer ENABLE_DIV = 1
```

在例化 Acore 时设置 `.ENABLE_DIV(0)` 即可关闭。
该参数同时传给译码器，并用 `generate` 控制除法单元是否实例化。
关闭后会移除除法运算硬件。当前尚无非法指令异常，关闭时的除法编码不写寄存器，
也不产生除法等待；关闭模式下的软件需要重新按 Zmmul/RV32I 编译，使用软件除法。

Makefile 提供同名参数，自动同时选择仿真硬件和默认软件 ISA：

| 开关 | 默认 ISA | 软件库 | 除法实现 |
| --- | --- | --- | --- |
| `ENABLE_DIV=1`（默认） | `rv32im` | RV32IM libgcc | 硬件除法 |
| `ENABLE_DIV=0` | `rv32i_zmmul` | RV32I libgcc | 软件除法 |

只需切换一个 Makefile 参数，即可对比 CoreMark，每组只运行一次迭代：

```bash
make coremark-verilator ENABLE_DIV=0 ITERATIONS=1
make coremark-verilator ENABLE_DIV=1 ITERATIONS=1
make test-divide
```

普通程序切换配置后先重新构建，再仿真，例如：

```bash
make build PROG=sort ENABLE_DIV=1
make iv PROG=sort ENABLE_DIV=1
```

RV32IM 的 CoreMark 结果保存在 `build/coremark/rv32im/`，Zmmul 结果仍在
`build/coremark/rv32i_zmmul/`。生成的 `result.json` 记录实际的 `enable_div` 配置。

专项验证使用 `TB_divider.v` 核对 2325 组请求和中途复位，再复用 `TB_Acore.v`
验证前递、load-use、寄存器重叠、乘除交替、分支/JALR、错误路径冲刷及 x0。
关闭时核对 576 个结果，开启时核对 586 个结果；关闭测试完全不编译两个除法器源文件，
证明处理器不依赖除法实例。乘法 1～5 级回归仍通过。
日志、定向程序和小型基准在 `build/divide/`，专项测试入口为 `make test-divide`。

按 `sort` 后接 Verilator 单次 CoreMark 的顺序完成整机回归，均通过；
CoreMark 两种开关下的 performance/validation CRC 都匹配。
另使用 `csrc/software/div_benchmark.c` 执行 200 次变化分母的无符号除法，
两种配置的校验和均为 `0xc672c720`。周期对比如下：

| 程序 | 关闭除法器 | 开启除法器 |
| --- | ---: | ---: |
| CoreMark performance，1 次迭代 | 378,292 | 378,160 |
| CoreMark validation，1 次迭代 | 379,209 | 379,113 |
| 除法密集小程序 | 54,248 | 8,814 |

CoreMark 性能组的提升约 0.035%，除法密集小程序约快 6.15 倍。
这些是仿真中的目标 CPU 周期，CoreMark 单次运行不足 10 秒，不能作为正式成绩。
尚未进行 FPGA 综合和静态时序分析，因此没有给出实际面积或最高频率结论。

## 进度
10.1   
还差五级流水线的冒险检测和前递模块没有设计，顶层也没有完成连线。 


10.1 23：37   
似乎完成了流水线骨架的搭建？还没有验证，不过也不好验证哈，之后完成冒险检测和前递模块的设计在统一一起仿真验证吧。 


10.2 15：36  
这次应该是真正完成了流水线骨架的搭建，并且我发现冒险检测与跳转检测并冲刷错误指令可以独立开来，所以目前完成了冲刷的判断。但是解决RAW的数据前递和配套的冒险检测模块都没有完成。下面讲述下这次提交的内容：
首先，最重要的是完成了顶层模块的连线，流水线每一级现在已经可以完成数据流动。从ID模块读出的 控制信号和数据 会随着流水线向下流动(当然不是全部数据全程流动，信号只需要流动到必要的阶段即可)。这里提几个重点：  
1、GPR数据是异步读取，严格来说可以随时读取，但考虑到不同指令可能都需要读取GPR数据，所以规定在EX同级进行读取，并在EX阶段进行锁存。虽然大部分需要读取GPR数据的指令都在EX阶段完成了消费，不需要额外存储，但是也有例外：S-type类型指令，他们在EX阶段消费rs1和立即数完成地址计算，在MEM阶段消费rs2数据写入内存。所以，核心顶层中使用了专门的寄存器在EX阶段读取并锁存。  
2、关于分支和跳转指令：原本的设计是打算根据ALU模块锁存后的输出，统一判断是否分支/计算跳转地址，发现这样需要冲刷两级流水线(ID/EX)，现在改进设计:将ALU的计算结果输出分成两路：一路是组合信号直接输出，第二路是经过锁存后的数据进行输出，两者结果相同，只有是否锁存的区别。由此，可以将组合信号结果直接作为计算是否冲刷的条件进行输出。好处：只需要冲刷ID阶段，节省了冲刷代价；缺点：组合逻辑变长，导致最大主频下降。    
3、完成了流水线骨架的搭建：ID产生的控制信号随流水线向下流动，并在每一级中都有锁存，冒险检测模块和前递模块可以以此为支点，检测数据冒险，并控制stall空泡和数据前递。并且现在比较明确的是：数据的消费都在EX阶段完成，并且数据的消费都是围绕GPR展开，那么也就是小心消费数据的前两个指令是否在生产消费的数据(是不是同一个寄存器)。具体的，一般的RAW只需要检查比R年轻的两条指令中是否存在W同一个地址的事件，特殊的，load-use中检查R年轻的1条指令中是否存在L同一个地址的事件。  
4、今天才发现，严格来讲我的流水线骨架不算是标准5级流水线，标准5级流水线需要pc取指后再锁存住指令。而我的指令是通过锁存pc组合取指的。考虑到紫光的ROM ip核可能不支持组合读取，所以后续会改成标准5级流水线，但是目前只是仿真验证阶段，改起来也比较容易，所以先不管吧，优先完成冒险检测和前递模块并仿真成功。  
这里介绍下标准5级流水线，以供后续参考： 
标准5级流水线如下：
[PC] → {IF → [IF/ID]} → {ID → [ID/EX]} → {EX → [EX/MEM]} → {MEM → [MEM/WB]} → {WB → [GPR]}  
[ ]：表示寄存器，{}表示流水线的每一级。其余则代表每一级中组合逻辑。我的代码则缺少[IF/ID]的寄存，直接使用PC组合读取ROM输出指令了。这么看我代码组织也不够好，感觉更好的组织方式是：用各种模块完成组合逻辑的设计，然后再顶层中例化这些模块并把结果存入寄存器当中，而不是把寄存器也放在这些模块内部。这样时序逻辑和组合逻辑就可以干净的分隔开，后续可以重构下。  
如果要加上IF/ID的话，前面的一些冲刷逻辑也需要修改，不过改的比较少，比如IF/ID在分支和跳转后也同样需要冲刷。  
5、再后续会考虑动态分支预测、M扩展、乱序和多发射来提高处理器性能。

10.3 23:13  
添加了冒险检测模块hazard_detection_unit，模块同时集成了冒险检测和数据前递功能。不过没有进行仿真验证。值得提一下的是：顶层稍微修改了下：增加了load-use冒险产生的空泡后，产生虚假指令的解决办法————空泡的控制信号全部失能，即处理为NOP。注意：在目前的设计中：由于冒险检测依赖ID阶段结束后的寄存器，即[ID/EX]中存储的值，因此，处理load-use冒险时，空泡是产生在EX级寄存器[EX/MEM]中。所以应当处理的是[EX/MEM]中的寄存器。  
另外需要说明，如果年老的两条指令都出发了同一个操作数的数据冒险，比如rs1_addr = rd_addr_EX = rd_addr_MEM，那么最后赋值的数据则是以较为年轻的优先，即rd_addr_EX所指向的数据。  
明天将会写整个系统的仿真并测试，祝好运。

10.4 12:04
改掉了ROM的组合读取方式，现在是真的5级流水线了

10.5 10:15
做了一点验证：先写了个简单的加法，然后写了个1-10的数列求和，运行成功了。不过没有覆盖所有指令。

10.6 12：08
使用汇编添加了一个简单的启动桩，实现了简单c语言程序的编译和运行，并且修改了ROM读取程序的方法，现在可以用make iv PROC=  *.hex来指定加载的程序。  
不过仍然存在问题：1、由于RAM没有预先加载数据，c的全局变量还无法加载进入程序当中 2、缺少规范的链接脚本，目前是依靠gcc第一个源文件为start.s的操作，才让启动桩放置在pc=0的位置。

10.7 17：11
1、修了一个比较重要的bug，Acore中分支和跳转的信号不受stall信号控制。  
当分支/跳转恰好碰上load-use冒险，即出现指令：
```
0x3c:  lw    a5,0(a5)
0x40:  bge   a3,a5,0x2c
```
触发stall的同时，lw也进入了ID/EX级，因此有可能误触发了Branch/Jump，由于设计缺陷，导致ID/EX级和IF/ID级寄存器没有stall，而是被冲刷变成了NOP。具体原因如下：

原本代码：
```v
wire branch_taken = Branch_ID & branch_cond;
wire jump_taken   = Jump_ID；
```
而 branch_cond 和 jump_taken 直接驱动pc是否加载 load_pc_en，load_pc_en又直接驱动flush信号，那么最后的结果就是pc被stall保持不变，但是ID/EX和IF/ID寄存器被冲刷成为了NOP。因此后续pc则跳转失败。  
正常的情况是：当冒险检测单元发出stall信号后，pc和IF/ID和ID/EX应该都保持不变。在ROM.v和decoder.v中，stall的优先级应该高于flash。当然，也可以在顶层补救，比如目前的方案就是：stall信号同样参与跳转/分支信号的驱动。如下：
```v
wire branch_taken = Branch_ID & branch_cond & ~stall;
wire jump_taken   = Jump_ID & ~stall;
```
2、另外，给Acore添加了一个简单的外设。目前地址分配:
```
    0x00000 ~ 0x07FFF    ROM
    0x10000 ~ 0x1FFFF    RAM
    0x30000 ~            外设 
```
目前支持：``` 地址：0x30000：可以写入程序退出码,一旦写入后仿真程序(TB_Acore)会检查结果并结束 ```   
```地址：0x30004：可以写入一些需要调试的数据，仿真程序(TB_Acore)会在终端直接打印出来 ```   
具体的访问地址的方式如下:(也可以查阅csrc/software/sort.c)
```c
#define EXIT  (*(volatile unsigned int *)0x00030000)
#define PRINT (*(volatile unsigned int *)0x00030004)

int main(){
    PRINT = 0xFFFF;
    EXIT = 0x1; // 1一般表示成功退出
}
```
另外，start.s中，当c的main函数正常退出后，同样会往0x00030000写入1表示正常退出。  
当然，为了防止程序真的出bug，TB_Acore固定了一个退出时间，为MAX_CYCLES = 500000;
