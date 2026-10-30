# M1：Acore 双发射与 DDR / W8A16 AI 逻辑移植

本文是 M1 阶段记录。M2 已把参考 HDMI/PCIe/物理 DDR 接入根顶层，板级 UART 已移除；
当前配置、初值切换和检查结果以 [M2 说明](video_integration_m2.md) 为准。

2026-10-29，分支 `ziguang_rv32i`。本阶段完成逻辑移植及行为短测试，未完成厂商 AI IP 验证或板级接入。
后续通信按用户最新决定改为 SPI；本次暂不修改 IIC、SPI 或它们的引脚。

## 已做的改动

从 `origin/main@9bd2479` 选择性移植 DDR 块搬运、跨域 CPU 窗口、五类 W8A16 算子、模型任务调度和检测后处理。
来源及原始文件 SHA256 记录在 `ai_import_manifest.json`，不复制主线 Acore/寄存器堆/取指路径。
自己的单/双发射 Acore、CSR、分支预测、ROM/RAM IP 和 CoreMark 镜像保持原实现。

`soc.v` 和 `peripheral_bus.v` 增加 `ENABLE_DDR`、`ENABLE_AI`、`AI_ACT_WIDTH`、`ENABLE_VIDEO` 及 DDR 用户口。
默认 DDR/AI/视频为 0；`board_top` 明确把未使用输入接到常量。
原有双发射入口 `acore_dual_top`、25 MHz、UART 和 IIC 继续保留，当前板级镜像不会自动开始推理。
新增 RTL 已加入唯一的根目录 PDS，没有新增另一个 PDS 工程。

CPU MMIO 的读返回仍是一拍，DDR 长延迟通过 BUSY/DONE/ERROR 寄存器协议体现。
CPU 可以在 AI 工作时执行其他代码；`ai_run_model` 当前使用轮询串行调度每条任务。
没有把 DDR 伪装成一拍 RAM，也没有让 CPU 使用普通 load/store 把栈放到 DDR。

| CPU 地址 | 功能 |
| --- | --- |
| 0x30200..0x30248 | AI 控制/状态/形状/地址/量化/操作码/计数 |
| 0x30300..0x30324 | 预留/可选按需视频抓帧；本阶段未启用 |
| 0x30400..0x30414 | 原 IIC FIFO/参数通道，保持不变 |
| 0x31000..0x31010 | DDR 窗口控制、状态、地址、长度、错误 |
| 0x31100..0x311fc | 256-byte CPU 数据窗口 |

CPU → 稳定参数邮箱 + request toggle → DDR 域执行 → 稳定结果 + ack toggle → CPU。
参数在任务期间冻结；窗口、AI 与可选抓帧以整个任务互斥使用本地块搬运器。
这只解决 SoC 内部的访问所有权，尚未实现与桌面视频环形缓冲/PCIe 的共享 DDR 仲裁。
接口为 x16 DDR 的原生 128-bit 用户口：字节地址右移一位，一拍前进 8 个原生单位；AW/W 与 AR/R 按厂商握手处理。

AI 支持 CONV2D、INT16 ADD、Concat、5×5 MaxPool、2× Upsample。
卷积执行通路为四个输出通道，每路每拍处理两个有符号 INT16×INT8 乘积，保留主线量化和溢出规则。
输入、权重、中间图和六张检测头均在 DDR；CPU 一次读取一条描述符，不在片上保存整网资产。
不引入 Cache，不改变现有 CPU 双发射的指令配对策略。

## 文件位置

| 内容 | 位置 |
| --- | --- |
| DDR 和算子 RTL | `rtl/ddr_cpu_window.v`、`ddr_block_transfer.v`、`conv2d_ddr_engine.v` 等 |
| CPU 模型调度/检测后处理 | `csrc/software/ai_runtime.*`、`ai_task_runner.c`、`ai_detection_runner.c`、`ai_postprocess.*` |
| 模型打包及原 C 参考导出 | `scripts/pack_ai_model.py`、`pc_ai/` |
| AI 专用链接脚本 | `firmware/ai_link.ld`，32 KiB ROM、64 KiB RAM，至少预留 16 KiB 栈 |
| 仿真模型 | `sim/models/` 和 `sim/ddr3/ddr3.sv`，不加入硬件 PDS |
| 短回归入口 | `scripts/check_ai_port.py` |
| 本轮固件 ELF/镜像/反汇编前的 map、日志 | `build/ai-port/`，独立于 CoreMark 初值 |
| 回归报告 | `reports/ai_port/short_checks.json` |

## 如何验证

在 WSL 的本仓库目录运行：

```bash
python3 scripts/check_ai_port.py --reference /mnt/c/Users/yyyyou71/Desktop/TridentVision
```

脚本使用 Verilator 5.052，编译同一份 RV32I 调度固件，然后分别用单/双发射 CPU 执行同一组模型。
包含 28 次模型请求、14 次实际算子提交，覆盖五算子混合网络、分组卷积、非法描述符、错误后的恢复与重跑。
每次逐字核对 18,252 个 DDR 字及哨兵/运行报告；期望算子结果取自原 TridentVision C 实现。
运行 25 MHz CPU 配置和 CPU/DDR 不同频率、随机停顿配置，不用 C 推理替代 RTL。
Verilator DDR 模型启用严格未初始化读检查，漏装载的整字会直接报错，避免两态零值掩盖问题。

另外用 Icarus 检查原生超时、故障跨域、运行中复位、共同复位后恢复，以及 AI 忙期间 IIC MMIO 仍独立工作。
发现 Icarus 12 在自动 task 内对动态片选的 `$isunknown` 可误报已知 0x01，DDR 行为模型改用等价的 XOR 四态判定。
新增负向检查确认：未使能字节的 X 不妨碍写入，真正使能的 X 字节仍报错；没有关闭未知值保护。

这些均为小任务短回归，未运行 CoreMark、99 任务整网长仿真或完整视频检测链。
另外已通过一个小卷积接双发射 CPU 检测后处理：核对 4,219 个 DDR 字、240 次 MAC issue 和 7 条检测记录。
检测固件 text=8,992 bytes，初始化 data/BSS=0，预留 16 KiB 栈；结果见 `reports/ai_port/postprocess.json`。
可选重现（第一条命令只打包模型元数据，不执行前向）：

```bash
python3 pc_ai/prepare_trident_network.py --reference /mnt/c/Users/yyyyou71/Desktop/TridentVision --out build/ai-port/model
python3 scripts/check_ai_port.py --reference /mnt/c/Users/yyyyou71/Desktop/TridentVision --postprocess-metadata build/ai-port/model/heads.json
```

后续整网入口已从主线移植，默认使用双发射并优先选择 `sim/models`，修改模型/RTL后缓存会失效。
`prepare_trident_network.py --core single` 可切回单发射对照；`--run` 仍须用户显式指定。
模型资产请通过 `--reference` 指向桌面目录，输出在忽略的 `pc_ai/outputs/`，不把大权重加入 Git。

## 紫光 IP 需要怎样准备

新增硬件包装只有厂商实例，仿真模型放在另一个目录，禁止把后者加入 PDS：

| 包装模块 | 厂商实例名 | 要求 |
| --- | --- | --- |
| `multiply_adder_w8a16` | `pango_ai_multadd` | signed 16×8 两乘积静态相加，25-bit，三级、CE、同步高有效复位 |
| `multiply_adder` | `pango_ai_multadd8` | 仅旧 W8A8 构建需要；signed 8×8 两乘积相加，17-bit，同样三级 |
| `video_async_fifo` | `video_fifo_ip` | 视频启用时需要；异步 128×512、标准同步读、关闭额外输出寄存器，异步高有效复位，读写水位端口开启 |

已依据本机 PDS 的 `ipm2l_multadd/index.xml` 和 pipeline 配置规则生成
`ipcore/pango_ai_multadd/pango_ai_multadd.idf`，尚未运行厂商生成器或把这个未生成的 IP 加入 PDS。
其三级设置为 INREG=0、PIPEREG1/2/3=1、OUTREG=0，Optimal Timing 关闭，动态加减关闭。
CPU 原有的 `pango_multiplier_ip` 继续独立使用，不用它替换 AI 的双乘积加法。

可重新准备配置（仅写 IDF）：

```powershell
python scripts/prepare_ai_ip_configs.py
```

按现有分工，由用户在 PDS 生成/导入上述 IP；启用 AI 前再核对端口、延迟、CE 和复位。
本阶段 `ENABLE_AI=0`，因此未生成的 AI IP 不属于当前板级活动层级。
真实 DDR IP 与 HDMI/PCIe 继续从已运行的桌面工程复用，下一阶段合并到一个物理 DDR controller/PHY。

## 下一阶段

M2 接入桌面 HDMI/DDR/PCIe 已验证模块，补完整突发归属仲裁、帧槽保留和跨域约束。
SPI 的 SCLK/MOSI/MISO/CS、模式和消息协议暂不动；模型调度和 DDR 接口不依赖传输方式。
实际启用 HDMI 时才移除与 `r_in[7]` 共用 AB21 的板级 UART。
新增系统资源以用户重新实现后的 `place_route/acore_dual_top.prr` 为准；时序见同目录 `.rtr`。
没有为本阶段声称已经完成新的资源/时序签核或实板推理。
