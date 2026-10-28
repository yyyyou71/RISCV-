# 可选 EVOLVE5 双发射核

来源是 `origin/kerman-cn-evolve5` 的 `a16b6e3` 快照中 `team_projects/kerman-cn-evolve5/project/rtl`。
保留 `rtl/` 下原始模块划分；源文件及上游对照见 `reports/evolve5/source_manifest.json`。
没有用它覆盖 `rtl/Acore.v`；单发射首次提交为 `e20bb3c`。

## 当前配置

- 五级受限顺序双发射，最多每拍退休两条，不是任意两条指令都可以配对。
- 四读两写寄存器堆、宽取指、四项取指队列、32 项 BTB、无 RAS。
- 开启副槽分支/JALR、共享 LSU 和受限乘法配对，RAW/WAW 等冲突退回单发射。
- I/D Cache 各 1 KiB、两路、16 字节行；D Cache 写穿透、不写分配。
- ROM/RAM 各 32 KiB，使用独立的紫光 IP；无外部 DDR、AI、视频或 IIC 接入。
- 25 MHz、UART 115200/8N1，板级引脚和电平与 Acore 一致。
- RV32I+Zmmul+Zicsr，硬件乘法、软件除法；`DIV_ENABLE=0` 时 DIV/REM 译码为非法指令，misa 不宣称完整 M 扩展。

Cache 数据阵列沿用上游异步读结构，使用逻辑资源；程序 ROM 和主 RAM 则明确例化块存储器 IP。
原来的 `rtl/soc/rv32_soc_memory.v` 只保留作参考，不加入本次编译；实际使用 `fpga/rv32_soc_memory.v`。
为避免 PDS 安装相关的 include 路径问题，GUI 工程使用已跟踪的 `generated/evolve5_design.v` 单文件快照。
应修改原模块，再运行 `python scripts/evolve5_sources.py` 更新快照，不直接编辑生成文件。
构建和导出会核对快照内容；克隆仓库后不依赖被忽略的 build 目录即可找到 GUI 的 RTL 输入。

## 与上游的有意差异

1. 将主存数组替换为官方 ROM / 真双口 RAM IP，保持突发接口和每拍读取时序。
   同一时刻只有一个主存命令，写入只发生在响应被接收时，复位会取消未完成写入。
2. 将乘法表达式替换为 `pango_evolve_mul`：32×32 无符号、64-bit 结果、IP 内零流水级。
   EVOLVE5 自己的乘积寄存器负责捕获结果，保留 FAST_MUL 的原始控制时序和高半部符号修正。
3. 增加 `DIV_ENABLE`，关闭除法请求与译码，并通过常量操作码使综合裁掉除法路径；不使用硬件 DIV/REM 的库。
4. 对未使用的副槽调试输出、D Cache 第二读输出显式留空，避免漏接端口警告。
5. 新增当前板卡顶层、MMIO 平台适配、RAM 初值、独立构建/审计及原生 PDS 工程导出。
6. Cache 标签在复位时清零，使其映射到 FF 而非有较大保持时间要求的分布式 RAM。
   标签有效位同时清零，因此不改变体系结构可见行为或 Cache 访问拍数；保留数据阵列的分布式 RAM 实现。

这不是与 Acore 接口兼容的直接替换件。未来把 DDR/AI 接到本核，需要适配其握手/突发总线和地址映射。
中断/CSR 保留上游实现；CoreMark 不打开 CPU 中断，timer 的比较中断也不启用。

## 地址与程序

| 地址 | 功能 |
|---|---|
| 0x00000000–0x00007FFF | 32 KiB 指令 ROM |
| 0x20000000–0x20007FFF | 32 KiB 数据 RAM，常量及初始化数据由 IP 预加载 |
| 0x40000000 / 0x40000004 | UART DATA / STATUS，bit0=1 可发送 |
| 0x40001000 / 0x40001004 | GPIO DATA / OE |
| 0x40002000 / 0x40002004 | 64-bit timer 低/高字 |
| 0x40002010 | timer CTRL，bit0=计数使能、bit1=比较中断使能 |

沿用 `third_party/coremark` 的未改动算法和 `csrc/coremark_port`。
`COREMARK_EVOLVE5` 只选择平台寄存器、启动横幅和 timer 初始化，不改动基准算法。
`start.S` 清 BSS；链接脚本预留至少 8 KiB 栈。程序结束打印 `COREMARK DONE` 并点亮 LED3，然后停留。
异常点亮 LED4；不要把 LED3 解释为独立 CRC 验证通过标志。

## 构建与证据

从根目录运行 `scripts/build_evolve5.ps1`，工具参数与单发射脚本相同。
默认 performance 2048 次迭代；`-SeedMode validation` 可切换种子。
步骤为两组官方 IP 单次 CRC / 退休窗口对照、最终长跑、最终 IP 全初值/字节掩码/乘法边界检查、
PDS 全流程、四角 setup/hold 审计和 `pds/evolve5.pds` 重新加载编译验证。

`reports/coremark/evolve5-*.json` 保存 CRC、真实 timer 计时窗口、退休数量及 IPC。
计时窗口内的副槽退休必须非零，仿真计数周期必须精确等于固件打印的 Total ticks；
不会仅凭 `DUAL_ENABLE=1` 就宣称双发射有效。
`evolve5-implementation.json` 保存物理资源、时序、输入和下载位流的 SHA256。
`scripts/check_evolve5_control.py` 另外运行真实指令程序，验证 RAW/WAW、四种乘法、字节访存、
非法 DIV 陷入，以及真实 timer 中断、GPR 恢复和 MRET；该项使用行为存储器模型，不替代实板中断验收。
长跑采用与官方 IP 单次周期/CRC 一致的行为模型，官方 IP 本身另外做全初值与乘法专项。

离线 CoreMark/MHz 不是实板成绩。Acore 与 EVOLVE5 的对比是两套核与存储层次的整体对比，
不能把性能差异全部归因于双发射；本次没有测量同一 EVOLVE5 核关闭双发射的正式长跑基线。
