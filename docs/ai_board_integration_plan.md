# Acore 双发射、IIC、HDMI、DDR 与 AI 板级集成

> 当前以 [阶段表](hdmi_ai_stages.md) 和 [P3a 首层集成](ai_first_layer_p3a.md) 为准。
> 已使用纯 SPI 终端，AI 默认开启、首层已接入；下文保留此前的规划和历史检查。
> 完整模型加载、99 任务后处理和画框仍未完成，首层检查不等于整网板测通过。

更新：2026-10-30。分支 `ziguang_rv32i`，唯一 PDS 入口为根目录 `rv32I.pds`。
已完成 M1 的 DDR/AI 逻辑移植；M2 的参考 HDMI/PCIe/物理 DDR、共享仲裁和帧锁定现已接入根顶层并通过新增逻辑短测试。
当前板级 UART 已移除，DDR 开启、AI 关闭，SPI 暂不动。PDS 编译/实现及实板验收由用户执行，
固件初值切换与本轮结果见 [M2 说明](video_integration_m2.md)；AI IP 生成仍待完成。

## 1. 已确认的目标和来源

- 保留自己的 Acore 顺序双发射、25 MHz、硬件乘法/软件除法，不引入 EVOLVE5。
- 先使用 `origin/main` 的 96×96 W8A16 网络、99 条任务和 RV32 后处理。
- HDMI 输入原图；FPGA 计算、坐标映射并画框，PCIe 将画框后的原图送给 RK3568。
- 最新决定：RK 与 FPGA 的模型加载/控制/结果通道改为 SPI；按用户要求本轮暂不改通信 RTL 和引脚。
  当前 IIC 通道仍保留；后文第 5 节的 IIC 分块协议与带宽计算是原方案记录，SPI 接口确定后再替换。
- RK 的 SPI 模式、速率、片选/引脚和消息协议尚未确定；DDR/AI 调度继续采用与传输方式无关的模型包。
- 桌面 `ziguang-fpga2` 的 HDMI、DDR 视频通路和 PCIe 由用户确认已上板运行，作为复用基线。
- 模型资产已找到：`C:/Users/yyyyou71/Desktop/TridentVision/training/export/rearch_int8.bin`。

主线核对版本：`9bd2479b0ce167a77bfa4ca22e1969984f06a236`；本地检查基线为 `c035675`。
两条分支历史没有共同祖先，采用按模块移植和接口合并，避免直接覆盖本分支的双发射 Acore。
不修改桌面参考工程；模型、训练数据和完整参考工程不整体复制进本仓库。

## 2. M0 检查结果及修正（历史记录，当前物理顶层见 M2）

| 项目 | 检查结论 |
| --- | --- |
| IIC 顶层 | `board_top.u_rk_iic` 已接入；`acore_dual_top` 透传 SCL/SDA |
| IIC 管脚 | SCL=P19、SDA=R19、LVCMOS33；与现有七个顶层端口的其他约束无重号 |
| 发送路径 | CPU → 64-byte 同步 FIFO → 1-byte 邮箱 → RK，RK 轮询读取并确认 |
| 接收路径 | RK 提交一个 32-bit 参数 → CPU 最新值邮箱，带版本号/待处理/覆盖标志 |
| 中断 | 未接入。`board_top` 将 `timer_irq` 接 0；SoC 现可透传该输入，IIC 没有 IRQ 输出 |
| CSR | 当前只支持 MTIP/MTIE bit7 和 `mcause=0x80000007`，没有 MEIP/MEIE bit11 |
| 地址冲突 | 原 IIC `0x30200..0x30214` 与主线 AI 冲突；已搬到 `0x30400..0x30414` |
| RK 协议 | 从机仍为 7-bit `0x66`；原 0x00..0x22 索引不变，CPU MMIO 搬迁不影响 RK 库 |
| PDS 顶层 | 合并后选中默认单发射的 `board_top`；已恢复 `acore_dual_top`，其 ENABLE_DUAL=1 |
| 实现选项 | 根 PDS 恢复双发射的多角时序/hold 修复配置，布局/布线种子为 2 |
| 存储器 | 双发射继续使用 pango_acore_fetch/pango_acore_ram；目标 PG2L100H/FBG484/-6 正确 |
| HDMI 引脚冲突 | 参考 `r_in[7]=AB21`，当前 UART TX 也是 AB21；接入 HDMI 时删除板级 UART 端口/约束 |
| AI / DDR / PCIe | 当前运行顶层尚未接入；现有 PCIe 文件只是导入准备 |
| 时序约束 | 当前仍是 CPU 小系统约束。新增系统要补 IIC 同步入口、多时钟 CDC 和 HDMI 输入时序，不能仅沿用 40 ns 时钟约束 |

修改已同步到 RTL、RV32 头文件、MMIO 测试、部署文档。旧 IIC MMIO 不再作为别名，测试验证旧地址不会误触发 FIFO。
独立 `firmware/iic_service/` 已按新地址重新编译；相同 ISA 镜像同时用于单/双发射检查。
恢复顶层不会自动把双发射 CoreMark IP 初值切换成 IIC 服务固件。若先测 IIC，需在 PDS 中将
`pango_acore_fetch` 和 `pango_acore_ram` 的初值分别选择服务目录的 `rom.hex`、`ram.hex` 后重新生成。
本轮没有生成 IP、综合、布局布线、烧录或运行 CoreMark。

本轮通过的短测试：存储器核/访存、独立 IIC、CPU FIFO/MMIO、板级 IIC、
单发射真实固件 IIC、双发射真实固件 IIC、板级自检及复位、RK 库 mock，共 9 项。
记录见 `reports/integration_review/checks.json`，详细日志在 `build/integration-review/`。
这些行为测试不代替新增系统的厂商 IP 仿真、物理时序和实板验收。

## 3. 模型资产与预处理约定

本轮使用主线导出器，只做资产打包/形状与地址检查/生产固件描述符校验，未执行整网前向。
产物位于 `build/integration-review/model_prepared/`，是临时检查产物，不是已上板镜像。

| 项目 | 数量或大小 |
| --- | --- |
| 原始 rearch_int8.bin | 10,297,508 bytes |
| 任务 | 72 CONV + 10 ADD + 14 Concat + 1 MaxPool + 2 Upsample，共 99 |
| 打包后的权重 | 10,186,624 bytes |
| 输入张量 | 294,912 bytes，96×96×align16(3)×INT16 |
| 特征图和输出 | 2,427,840 bytes |
| 完整调试模型包 | 13,307,184 bytes，约 12.69 MiB |

权重 SHA256：`ffabd646534f212e323afbb67038d14ff5d34fe01e54cd43af61b2aa87c8637b`。
模型使用主线 AIM1 v2 / AIR1 / AIP1 格式，保留任务、头图地址、量化参数与定点后处理规则。
六张检测头不等于一张输出图；继续使用六头描述符和主线两次 Top-K，不擅自添加 NMS。
现有资产报告指向色块训练；80 个输出通道不能据此当作已验证的 COCO 通用检测能力。

HDMI 图像输入沿用主线 `verify_trident.py:prepare_image`：RGB 顺序、adaptive average pooling 到
96×96、0..255 INT16 像素码，均值采用 ties-to-even 舍入；随后转换为 HWC、通道补齐到 16 并填零。
不随意改成最近邻、归一化浮点或 letterbox。池化边界为 floor(start)、ceil(end)，相邻区域可能重叠。
计划从原始 RGB888 分支生成 AI 输入，再将原图保存成参考视频通道的 RGB565，避免从 RGB565 还原后声称输入逐值一致。
坐标从 96×96 分别按原图宽/96、高/96 逆映射、裁剪；Q16 负数和越界框先检查，再交给画框模块。

## 4. 总体数据流与 DDR 所有权

```text
RK -- SPI 模型包/控制 --> RX 分块缓存 --> Acore 调度 --> DDR 模型区
RK <-- SPI 检测记录 ---- TX 消息队列 <-- Acore 后处理 <-- AI 检测头

HDMI RGB888 --+--> 锁定帧的 RGB565 原图 --> DDR 视频区 --+--> 画框叠加 --> PCIe --> RK
             +--> 96×96 池化/格式化 -----> DDR AI 输入 --> AI 加速器
                                                       （结果关联同一 frame_id）

DDR 视频写、视频读、AI/CPU 窗口、预处理写回
                  --> DDR 用户口仲裁 --> 一个板载 DDR3 IP
```

只使用一个物理 DDR3 controller/PHY。参考 `frame_ring_ddr3` 内已经例化了 DDR3 IP；
移植主线 `ddr_cpu_window` 时必须连接这个共享用户口，不能再实例化第二个控制器驱动同一组引脚。
尽量保留参考 `u_hdmi_fifo.u_ddr3` 和 PCIe IP 的已知实例层级，减少 PHY/收发器固定位置约束迁移。
CPU 的程序/栈/普通数据继续在片上 ROM/RAM，CPU 通过块窗口管理 DDR，不把 CPU 同步 RAM 直接换成 DDR。

暂定物理字节空间：`0x00000000..0x03ffffff` 预留视频与帧槽；
`0x04000000..0x07ffffff` 为 AI 管理区、模型、输入和工作区；剩余空间保留。
AI 继续使用从 0 开始的逻辑 DDR 字节偏移，在 AI 用户口边界统一平移到物理 AI 区，检查跨区/溢出。
这样可保留 AIR1/AIP1 低地址常量和模型内部指针，不靠只移动 model.bin 文件来“重定位”。
正式地址表须核对参考通路的真实原生地址步进；不能仅按 FRAME_SHIFT 的注释推算物理字节占用。
主线默认 x16 的换算是 `native=byte_address>>1`，每个 128-bit beat 前进 8 个 native 单位。

仲裁按完整 DDR 突发锁定归属。写口在 AW 握手后保持 owner 到 WREADY/WLAST；
读口在 AR 握手后保持 owner 到 RVALID/RLAST，禁止只复用地址而把返回数据送错客户端。
这是厂商 pull-write/push-read 用户接口，没有 AXI 标准的 WVALID/RREADY；必须先备齐写突发、预留整段读缓存。
对不可背压的 HDMI 用 FIFO 水位提升写服务优先级，同时给 AI 和 PCIe 有界公平服务，避免超时/饥饿。

帧槽计划：FREE → CAPTURING → READY → INFERENCING → RESULT_READY → PCIE_SENDING → FREE。
选中帧从开始采集到结果发送完成始终受保护；不能在 AI 运行期间被环形写指针覆盖。
检测结果、预处理配置、PCIe 输出与 IIC 文本记录携带同一 frame_id。
第一版按可用槽抓帧、忙时丢弃新帧，先实现正确的完整闭环，不把 HDMI 输入帧率当作 AI 推理帧率。
画框放在 DDR 读出到 PCIe 的流通路上，不由 CPU 对整帧逐像素读改写。

## 5. IIC 分块传输与中断

当前“32-bit 最新参数 + 1-byte 邮箱”适合控制，不足以可靠装载权重。
保留旧寄存器，新增能力/版本查询、RX 分块缓存、TX 结果消息接口。
新包至少包含 opcode、session/model 标识、seq、目标逻辑偏移、长度、payload 和 CRC32。
块大小按缓存与 RK 控制器能力协商，初版可用 128/256 bytes；IIC 每次事务不能越过已定义的寄存器窗口。
主机先确认空间再写，完整校验/提交后 FPGA 才报告应用级 ACK；总线 ACK 不等于数据已写入 DDR。
相同 seq 的重试须返回原确认而不重复消费；用 offset/seq 区分乱序、丢块和跨复位会话。
仅在整包长度/范围/CRC 验证通过后设置 MODEL_READY，写 DDR 的范围受限于模型区。
加载与运行互斥；推理期间不允许修改权重/任务表。复位或 DDR 重新初始化后模型状态失效。
结果消息至少含 frame_id、模型标识、图像宽高、类别 ID、Q0.16 置信度、原图框坐标、错误与计时。
“文本”第一版是这些检测记录的文本表示；当前模型不实现 OCR 字符识别。

IIC 带宽需提前接受：仅 10,186,624-byte 权重，按每字节 9 个 SCL 周期估算，
100 kHz 理想下限约 15.3 分钟，400 kHz 约 3.8 分钟；协议开销与调度会更慢。
权重上电加载一次后常驻 DDR，不能每帧重传。保留用户指定的 IIC 权重路径，先测 100 kHz，再验证提高 SCL 的能力。
HDMI 芯片配置 IIC 是另一组 AA21/AA20，FPGA 在该接口为主机；RK 通信 IIC 为 P19/R19，从机 0x66，两者不混接。

中断方案为 CPU 增加 machine external interrupt：MEIP/MEIE bit11、mcause=0x8000000b；
保留原 timer bit7 和原双发射原子提交/返回逻辑。增加小型 pending/mask/ack 控制器，预留 MMIO 0x30500。
IIC 接收完成、AI 完成、视频完成和错误保持为 pending，软件处理并确认后清除，不用一个周期的脉冲直接触发 CPU。
多个来源由 pending 位区分；明确同时置位/清除时新事件优先。RK 侧继续主动轮询，无需假定另有 FPGA→RK 中断线。
先以轮询跑通 DDR/AI，再切换为可选中断，避免通信、计算和中断一起调试。

## 6. 实施阶段和验收

| 阶段 | 改动 | 完成标准 |
| --- | --- | --- |
| M0 本轮已完成 | 工程审查、IIC MMIO 搬迁、恢复双发射、模型资产检查 | 9 项短测试通过；模型 99 描述符、形状和范围检查通过 |
| M1 逻辑已移植，IP 待验证 | 选择性移植 main 的 DDR 窗口/块搬运和 W8A16 算子；准备 Multiply-Adder/FIFO IP 边界；保留双发射 | 已通过五算子混合、非法任务、DDR 随机等待；待生成真 IP 并检查延迟/CE/复位 |
| M2 代码和短测完成，待用户实现/上板 | 复用桌面 HDMI/DDR/PCIe，移除 UART 板级端口，加入共享 DDR 仲裁、地址保护、帧锁定和域复位 | 新增逻辑短测试通过；物理顶层结构及引脚/来源静态检查通过；待上板验收 |
| M3 暂不修改 | SPI 分块模型加载、RK 加载/监测工具、RV32 服务固件；取代原 IIC 方案 | 从 RK 装载测试块并回读；重试/CRC/越界/断传/复位检查；完整模型 MODEL_READY |
| M4 | 固定输入运行 99 任务和 CPU 后处理 | 使用相同输入/资产与主线结果比较；短回归由代理完成，整网长仿真由用户启动；实板返回正确状态和检测记录 |
| M5 | 帧锁定、RGB888 池化/格式化、坐标映射、流式 RGB565 画框 | 固定图逐值预处理检查；PCIe 原图画框与 IIC frame_id 对应，旧帧不被覆盖，慢消费可恢复 |
| M6 | 外部中断、连续多帧、加载后重启和错误恢复 | 单/双发射 IRQ 回归、并发事件与返回 PC 正确；持续输入和 RK 停读/断链不会静默错帧 |
| M7 | 最终 PDS 交付、资源与时序检查、演示记录 | 根工程唯一入口；模型/帧延迟、推理 FPS、DDR/FIFO 高水位可读；用户完成实现与烧录 |

原理图/HDMI/PCIe 基线不重新当未知硬件排查；验证集中在新加的仲裁、帧所有权、CDC、预处理和协议。
主线 Multiply-Adder 和 video FIFO 仍有行为替代边界，不能把仿真模型直接作为厂商 IP 已完成的证明。
本轮没有运行长 CoreMark 或完整 AI 仿真；之后也不自动运行长基准。Verilator 5.x 用于大规模快速仿真，
Icarus 保留四态和异常定向检查；当前 WSL 已安装并验证 Verilator 5.052。
PDS 的实现和烧录由用户操作；IP 清单、初值选择和完整约束随每阶段源代码一同更新。

## 7. 报告和运行文件在哪里看

- 本轮检查：`reports/integration_review/checks.json`。
- 模型打包检查：`build/integration-review/model_prepared/prepared.json`、`layout.json`。
- PDS 资源：`place_route/acore_dual_top.prr`。
- PDS 时序：`place_route/acore_dual_top.rtr`。
- PDS 时序摘要：`place_route/acore_dual_top_timing_summary_after_hold_fix.txt`（启用 hold 修复时）。
- 新位流：`generate_bitstream/acore_dual_top.sbit`。

资源/时序文件以用户本次实现结束后的时间戳为准，历史 CoreMark 报告不代表新增 IIC 或未来 AI 系统。
赛题 1 还列出两路组相联 I/D Cache 和完整异常/中断作为高阶任务；本计划专注用户当前选定的 AI 应用闭环，
不将当前无 Cache、有限中断的 Acore 表述为已经完成全部高阶指标。
