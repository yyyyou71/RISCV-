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
处理器仍按 RV32I/ILP32 编译，浮点计算由 `libgcc` 用整数指令实现，不要求 F/D 扩展。
移植层的 `cvt.c` 负责浮点转字符串，并在本地实现小数/整数拆分，避免依赖 libc/libm。
脚本会核对 CPU 打印的小数与原始周期计算结果是否一致；`result.json` 保存未按六位小数截断的结果。
短于 10 秒的目标运行会保留原版 CoreMark 的时长错误，仅标为短运行估算。
增加迭代次数后，脚本仍独立检查 CRC，并按原始周期计算性能。
这属于当前 RTL/存储器模型的仿真结果，50 MHz 是设定的目标频率，未证明 FPGA 时序收敛。

## 乘法扩展：RV32I + Zmmul

支持 `MUL`（低 32 位）、`MULH`（有符号×有符号的高 32 位）、
`MULHSU`（有符号 rs1×无符号 rs2 的高 32 位）、`MULHU`（无符号×无符号的高 32 位）。
这是 Zmmul 乘法扩展，尚未实现完整 M 扩展中的 `DIV/DIVU/REM/REMU`。
当前未接入非法指令异常，不支持的除法编码不会写寄存器，但也不会计算除法结果。

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

不传 `ISA` 时保留原来的 `rv32i` 默认值。本机 GCC 10 不识别 `-march=rv32i_zmmul`，
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
除法暂时保留软件实现；若后续需要完整 RV32IM 或应用频繁执行整数除法，
再增加迭代除法器，并覆盖除零和有符号溢出等边界。

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
