# EVOLVE5 实现验证与IPC报告

2026-10-23，离线验证与发布；实板待验收。本阶段完成独立GCC编译对照、第二槽控制流／访存／乘法、精确部分提交、存储命令快路径、低延迟DSP乘法及针对性BTB/RAS/gshare比较。ISA保持RV32IM+Zicsr，时钟25MHz。

## 结果

以下均为performance/validation各8次迭代的RTL仿真，标准CRC通过；不足10秒，score_valid=0，不是正式实板CoreMark成绩。IPC按同一实际计时窗口的独立退休事件数除以周期数，并与minstret快照交叉核对。

| 阶段 | performance周期 | 退休指令 | IPC | validation周期 | validation IPC |
|---|---:|---:|---:|---:|---:|
| dual1 | 2743123 | 2528167 | 0.921638 | 2746714 | 0.921717 |
| compiler_lto | 2639705 | 2451118 | 0.928558 | 2642987 | 0.927045 |
| branch_pair | 2512474 | 2451118 | 0.975579 | 2516811 | 0.973520 |
| shared_lsu | 2475998 | 2451118 | 0.989952 | 2481012 | 0.987568 |
| fast_store | 2317684 | 2451118 | 1.057572 | 2323304 | 1.054605 |
| fast_mul | 2325918 | 2451118 | 1.053828 | 2330932 | 1.051153 |
| fast_both | 2167604 | 2451118 | 1.130796 | 2173224 | 1.127434 |
| tuned_without_mul_pair | 2146614 | 2451118 | 1.141853 | 2151912 | 1.138600 |
| balanced | 2139188 | 2451118 | 1.145817 | 2144808 | 1.142371 |
| speed | 2118198 | 2451118 | 1.157171 | 2123497 | 1.153836 |
| unroll_candidate | 2161048 | 2356480 | 1.090434 | 2172205 | 1.087922 |

fast_store与fast_mul均以shared_lsu为基线做单因素实验，fast_both才是两者组合；不能把独立实验看作逐行叠加。balanced使用BTB32/RAS0，speed使用BTB256/RAS8，两者均支持第二槽乘法。

speed相对DUAL1的performance总周期减少22.78%，同工作量加速29.50%。旧固件换编译器会改变退休指令数，因此不能把全部IPC变化都归因于硬件。硬件步骤使用冻结的同一GCC15 O2+LTO固件比较。

编译对照选择GCC15.2 O2+LTO，18776字节。受控O3展开在旧架构更快，但在最终更宽配对硬件上反而更慢，故未采用。官方算法源文件MD5及SHA-256校验不变，所有算法文件使用相同flags，未链接预编译算术库。未做PGO。

## 实现边界

五级流水，顺序执行与退休，最多每拍两条。一组最多一条访存、一个M操作。第二槽支持整数ALU/LUI/AUIPC、条件分支、对齐直接JAL、JALR、load/store及MUL/MULH/MULHSU/MULHU；DIV/REM仍在第一槽。同对RAW/WAW拒绝，WAR允许。不需要第二个LSU或第二个乘法器。

较老指令异常取消第二槽；第二槽异常则先提交第一槽，再在下一拍从主退休口提交第二槽异常，阻止年轻访存和MDU逃逸。第二槽未对齐JALR/load/store和总线错误都保留精确mepc/mtval；直接分支的静态未对齐目标退回原单槽路径。CSR/系统指令串行，FENCE不配对；全部存储仍等真实响应，未引入posted store。

FAST_STORE仅把命令从Cache IDLE直接发出，省去一次内部SINGLE_CMD等待，保留响应、错误及字节写语义。FAST_MUL在握手时捕获乘积，低位MUL更早返回，高位结果随后作符号校正；仍只有一个在途M操作，并非可每拍接收新乘法的完全流水MDU。

I/D Cache各1KiB、两路、16字节行；ROM/RAM各32KiB；后端四拍突发。双字I-Cache读口有副本，逻辑Cache容量不变。没有新增DDR、PLL、乱序、ROB、寄存器重命名或新ISA扩展。Zb*/Zicond属于后续条件候选，未纳入本轮同RV32IM优化。

## 预测器比较

| 配置 | performance两次周期 | validation两次周期 |
|---|---:|---:|
| fast_both | 542067 | 543170 |
| fast_btb128 | 538922 | 540179 |
| fast_btb256 | 537791 | 538957 |
| fast_btb64 | 539541 | 540625 |
| fast_combo | 536799 | 537857 |
| fast_gshare | 538001 | 538418 |
| fast_ras8 | 540821 | 541806 |

BTB256+RAS8获得本轮最好结果；gshare没有进一步胜出。发布balanced采用BTB32/RAS0，speed采用BTB256/RAS8；两者都启用完整两槽配对和快路径、使用同一固件。

## 验证与时序

最终配置通过RV32I 469场景/233261条差分退休包、RV32IM 160场景、共享LSU 140专项、第二槽乘法148专项、机器态78场景。数据副作用及两个退休包逐条对比独立Python模型。机器态包含第二槽等待中的IRQ及第二槽错误优先于IRQ。

快速乘法RTL和PDS映射后网表各通过17952组算术、48组取消/复位/背压场景，实际4个GTP_APM_E2 DSP。映射仿真使用本机PDS模型，仅为功能仿真，没有SDF；模型不复制进交付包。快速存储10组Cache配置的错误、复位、边界及稳定握手通过；因相关RTL文件完全相同，这些结果在reference/evolve4_checks保留并核对源一致性。

| 配置 | LUT | FF | DSP | DRM | setup slow/fast ns | hold slow/fast ns |
|---|---:|---:|---:|---:|---|---|
| balanced | 9307 | 4991 | 4 | 16 | 11.744/22.603 | 0.130/0.020 |
| speed | 10954 | 5995 | 4 | 16 | 12.392/23.096 | 0.230/0.083 |

PDS 2022.2-SP6.1，PG2L100H-6IFBG484，保持40ns和0.200ns原预算；setup报告含工具jitter为0.250ns，hold0.200ns。未新增内部路径例外。16块DRM为ROM8/RAM8；实际映射INIT反解8192字与固件逐字一致，复位FF初始化及全部时序角通过。此结果仅证明25MHz通过，没有验证最高稳定频率。

先前EVOLVE4的seed1/seed2保持失败保留在reference/phases；EVOLVE5 speed_s4及speed_s6也未通过保持审计，报告在reports/pds。最终发布balanced_s4和speed_cluster_s1均通过原约束，不下载失败候选的work位流。中断测试曾因快速MUL不再经过旧状态、以及冷Icache没有实际形成第二槽而失败；修正注入/预取后78场景通过。EVOLVE5初始MIMPID位与旧BTB字段冲突造成启动自检失败，已移至bit13，并保持固件不变。所有失败证据保留。

## 身份与验收

共同固件BUILD=EVOLVE1_BOARD，这是冻结软件阶段的名字；完整硬件版本由MIMPID、FRONT_CFG、发布清单和位流哈希区分。MISA=40001100、HW_CFG=0000003F、ISSUE_CFG=d1000003。balanced IMPL_ID=000325ff，speed=000328ff。不要仅凭BUILD判断烧录版本。

MIMPID bit1=第二槽JALR、bit4=直接分支/JAL、bit5=访存、bit6=快速store、bit7=快速MUL、bit13=第二槽MUL；原bit0 BP、bit2 DUAL、bit3 WIDE及bits12:8的BTB宽度字段保留。

下一步按上板验收说明，实际下载两版各3轮b 2048，保存完整启动、两套结果至最后CM_READY、下载日志和位流SHA。验证KEY0真实复位。旧STRESS1/DBG1实板结果不等于本版长压力/真实抓波已通过。RV32IM的赛题扩展计分口径仍待确认。
