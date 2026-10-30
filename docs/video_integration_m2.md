# M2：按现有工程移植 HDMI / PCIe / 共享 DDR

更新：2026-10-30；分支 `ziguang_rv32i`。唯一维护入口为根目录 `rv32I.pds`，顶层仍为 `acore_dual_top`。
本阶段完成新增连接和短测试，PDS 编译、实现和烧录由用户完成。

### PDS 工程格式修复记录

2026-10-30 修复根工程第 88 行的 Flow-0130 / Flow-0121：简写的源码和 IP 条目缺少
PDS 必需的 `_timespec`，不是 Verilog 第 88 行出错。一次补齐了 62 个 `_file`、5 个 `_ip`
和 128 个 `_ip_source_item` 条目的时间字段，并由本机 PDS 2022.2-SP6.1 重新整理原生格式。
`export_project.py` 现在会补齐这些字段，`audit_video_project.py` 会检查缺项；括号平衡检查不能代替原生解析。
已在 PDS 图形界面确认根工程成功打开，器件为 PG2L100H-6FBG484、顶层为 acore_dual_top。
记录见 `reports/video_integration/pds_project.json`。

命令行检查曾进入默认流程，随后结束；另一次限制到 Compile 的检查在 120 秒后超时，
不能记为 Compile 或综合通过，也没有完成布局布线、时序验收或生成新位流。
后续手动编译请使用根工程。PDS 的 `-project` 不指定 `-run` 会继续默认流程，不可当作只读语法检查。

## 1. 来源与移植边界

| 部分 | 来源 | 本轮改动 |
| --- | --- | --- |
| CPU | 本分支 `20f4da7` 的自有 Acore 顺序双发射 | Acore、译码、寄存器堆、配对、前递、取指队列和 CSR 未改 |
| AI | 先前从 `origin/main@9bd2479b0ce167a77bfa4ca22e1969984f06a236` 导入 | 未重新设计或重跑 AI 回归；物理顶层 `ENABLE_AI=0` |
| HDMI 配置 | 桌面 `ziguang-fpga2/source/source/hdmi/` | 沿用 MS72xx 配置；删除一个重复输出 net 声明，逻辑不变 |
| 视频帧缓存 | 桌面 `hdl/new_ring/` | 保留 FIFO、数据布局、marker 和控制器；添加帧槽保护/帧号/完整性判据 |
| PCIe、DMA | 桌面 `hdl/pcie_dma_test.v`、`hdl/pcie_dma_ctrl/`、`ipcore/pcie_test/` | 原顶层改名为 `acore_video_platform`；DMA 文件经行尾归一化后与参考相同 |
| DDR、PLL、FIFO | 桌面 `ipcore/{ddr3,PLL_CLK,fifo_2_ddr,ddr_2_fifo}/` | 复制已生成的综合依赖与 IDF，未更改 IP 参数 |
| 新增集成逻辑 | 本仓库 | DDR 仲裁、CPU 区域隔离、帧锁定邮箱、视频尺寸/帧周期观测 |

没有修改桌面原工程。175 项来源文件、原始 SHA256、移植后 SHA256 和 5 处适配说明见
`video_import_manifest.json`。其中包含此前已经导入、与桌面版本一致的 PCIe DMA 文件，并非全部都是本轮新增。
新增顶层从参考顶层适配而来，保留 PCIe/DMA/弹性数据管线；参考的旧车牌检测流水线暂时旁路，送出 RGB565 原图。

## 2. 当前活动层级

```text
acore_dual_top
  u_board: board_top (25 MHz，自有双发射 CPU，IIC 保留，UART 无板级出口)
    u_soc: soc
      u_core: Acore
      u_peripheral_bus
        g_ddr.u_window: ddr_cpu_window
        g_frames.u_frames: frame_mailbox
  u_video: acore_video_platform (参考 HDMI/PCIe 平台)
    u_video_monitor: video_timing_monitor
    u_hdmi_fifo: frame_ring_ddr3
      u_detector: hdmi_in_detector
      u_write_ctrl / u_read_ctrl (原 FIFO IP 保留)
      u_arbiter: ddr_native_arbiter
      u_ddr3: 参考物理 DDR controller / PHY，只有这一套
    u_ips2l_pcie_wrap / 原 DMA 与 PCIe 数据管线
```

CPU 参数为 `ENABLE_DUAL=1`、`ENABLE_DDR=1`、`ENABLE_FRAME_CONTROL=1`，AI 默认关闭。
`board_top` / `soc` 的可复用默认参数仍关闭可选外设，供原来的 CPU 仿真使用；不能由其默认值推断物理顶层未接 DDR。
原指令 ROM 32 KiB、数据 RAM 64 KiB、三拍硬件乘法均保留紫光 IP，仿真数组不加入 PDS。

## 3. 共享 DDR 和地址

视频客户端为仲裁器 0，CPU/未来 AI 窗口客户端为 1。AW/W 和 AR/R 独立轮询，
一旦选择客户端，地址反压期间以及整个突发期间保持所有权，到最后一拍才释放。
紫光原生端口没有 WVALID、RREADY 和 B 通道，因此写端按 WREADY 供数、读端在 AR 前预留容量。
仲裁器核对响应 ID、拍数与 LAST；发现异常后置粘滞故障，停止接受新事务，公共复位恢复。

| 用途 | 地址/容量 |
| --- | --- |
| 视频保留区 | 物理字节地址 `0x00000000..0x03ffffff`，64 MiB |
| CPU/AI 逻辑区 | 逻辑字节地址 `0x00000000..0x03ffffff`，64 MiB |
| CPU/AI 对应物理区 | 物理字节地址 `0x04000000..0x07ffffff`，64 MiB |
| CPU 自检 scratch | 逻辑 `0x03fff000`，256 bytes，本阶段专用 |

CPU 仍通过 `0x31000` 控制寄存器和 `0x31100` 数据窗口分块搬运；DDR 不是普通 CPU 一拍 load/store RAM。
`ddr_block_transfer.LIMIT_BYTES` 在产生原生事务前检查逻辑范围；超过 64 MiB 的请求以 `ERROR_CODE=3` 返回。
帧环入口另做原生地址加突发长度检查，再给 CPU 原生地址加 `0x02000000`，即物理字节偏移 64 MiB。

**保留参考工程的地址单位与空隙**：原生 x16 地址单位为 2 bytes。视频槽基址是 `slot << 22` 原生单位，
相邻槽相距 8 MiB；一次突发携带 256 bytes，但原控制器的下次起始地址增加 256 原生单位，即间隔 512 bytes。
读写两侧一致，本轮没有修改这一已上板的布局。五帧占用低端约 40 MiB 地址范围，因此为视频保留 64 MiB。
后续 AI 读取视频必须按该步长寻址，不能将原始视频当成连续的 CPU 逻辑区。

## 4. 帧槽保护和 CPU 寄存器

写端在 SOF 选择下一个未保护的槽，读端保护正在送往 PCIe 的槽；CPU 可同时保留一个完整帧。
读端和 CPU 都在取得槽的同一拍提供预保护，避免与写端 SOF 同拍争用。
槽全被保护时继续排空输入 FIFO、丢弃整帧，直到后续 SOF 有空槽再恢复。
只有突发数正确、输入形状有效且没有丢弃的帧才发布完成位和 32-bit 帧序号。
沿用参考的“下个 SOF 发布上一帧完成”机制；最后一帧停在画面结束处时不会凭空发布完成。

CPU 通过稳定参数与 request/ack toggle 跨域；参数保持到应答、结果保持到下一条命令。
帧号按模 2^32 的有符号差比较新旧；重复 acquire 保持当前 lease，不暗中换帧。

| CPU MMIO | 功能 |
| --- | --- |
| `0x30600` W | 写 1 获取最新完整帧；2 释放；4 清 DONE/ERROR；忙时不接受新命令 |
| `0x30604` R | bit0 BUSY、1 HELD、2 DONE、3 ERROR、4 DDR_READY、5 SHARED_FAULT |
| `0x30608` R | 保留槽号 0..4 |
| `0x3060c` R | 保留帧号；HELD=1 时有效 |
| `0x30610` R | 保留槽原生地址 `slot << 22`，不是字节地址 |
| `0x30614` R | 视频突发起始地址步长，256 原生单位 |
| `0x30618` R | 一帧有效 RGB565 数据量，4,147,200 bytes |
| `0x3061c` R | 最近观测的 `(height << 16) | width` |
| `0x30620` R | 最近 VS 周期，单位为 25 MHz sys_clk 的周期 |

形状监测直接观察原始 VS/DE，逐行检查 1920 像素、每帧 1080 行；形状不符时停止接收并使当前帧无效。
形状恢复后可重新接收。帧周期由实际 VS 测量，没有硬编码 60 Hz；例如可用 `25000000 / period` 估算刷新率。
原参考 SOF marker 仍保留，不宣称 PCIe 内容是逐像素无标记的 RGB888；当前还没有 AI 画框或 RK 端帧号协议。

## 5. 引脚、时钟与复位

`board/pins.fdc` 沿用桌面活动约束，实例路径增加 `u_video.` 前缀，参考按键/LED 名映射到现有名称。
88 个普通 IO 均有唯一管脚，PCIe 串行通道由原 PHY PAP_LOC 定位；全部活动 IP 为 PG2L100H/FBG484/-6。
UART 板级端口和约束已删除，AB21 只属于 `r_in[7]`；RTL 内 UART 可供历史 CPU 仿真，物理串口没有输出。
IIC 仍为 P19/R19、3.3 V、地址 0x66、CPU MMIO `0x30400`，没有新增中断；SPI 模式、协议和引脚暂不动。
参考中注释掉的 HDMI reset 管脚未凭空分配，平台保留其内部输出，物理根顶层不引出。

DDR/PCIe 继续沿用参考公共复位，CPU 复位也受该公共复位控制，避免只复位一个 mailbox/原生事务端。
`board/timing.fdc` 保留 PHY/PCIe 生成时钟和参考关系；新增 HDMI pixel 时钟按 148.5 MHz 上限约束，CPU 为 25 MHz。
新增 mailbox 数据路径设置跨域最大/最小延迟，只对首级同步寄存器 D 端设置定向例外。
PDS 实现后需检查这些层级名是否实际命中；当前没有通过综合后的名称、时序收敛或板级输入裕量验收。
HDMI 外部 input delay 沿用参考的已有信息范围，没有编造接收器延迟；新时钟约束不等于已完成外部 IO 时序签核。

LED0（J16）高表示同步后的 DDR ready；LED1（M17）高表示 CPU 错误 GPIO 或共享 DDR 故障。
这是 RTL 电平定义；板上实际亮/灭取决于 LED 电路极性。LED0 不独立证明 CPU 自检或视频传输成功。

## 6. 上板固件选择

新程序为 `firmware/video_bringup.c`，已由 WSL GCC 10.2.0 编成 `firmware/video_bringup/` 下的 hex。
它不打印串口、不启动 AI；等待 DDR 后做隔离区写/读、逻辑越界拒绝及恢复检查，随后循环获取/释放帧。
失败置 GPIO=2；成功置 GPIO=1。成功 GPIO 当前未单独映射到物理 LED，测试台核对它，板上可经调试信号观察。

**本轮没有重新生成 CPU 存储器 IP。现有 IP HDL 的 INIT 仍是原来的 CoreMark，不会因添加 hex 自动改变。**
上板使用新自检程序前，在根工程的 IP 配置中：

1. `pango_acore_fetch` 的 INIT_FILE 选 `firmware/video_bringup/acore_dual_rom.hex`。
2. `pango_acore_ram` 的 INIT_FILE 选 `firmware/video_bringup/acore_dual_ram.hex`。
3. 重新生成这两个 IP，保持宽度、深度、双口和 TRANSPARENT_WRITE 等参数，再从根 PDS 运行后续流程。

不要使用 `acore_dual_ram_bytes.hex` 配置 IP；它是 byte-array 行为仿真专用。
固件 manifest 保存编译参数和 SHA256；自检正文只有 612 bytes。重新编译 C 的命令为：

```bash
python3 scripts/build_firmware.py --app video_bringup --core acore_dual --image-dir firmware/video_bringup
```

历史 `scripts/build_fpga.ps1` / `build_acore_dual.ps1` 会生成并覆盖 CPU-only 工程，因此当前检测到 M2 后直接停止。
本阶段请直接使用唯一根工程 `rv32I.pds`，不运行历史导出/实现脚本。
`prepare_ips.py --core acore_dual` 的默认路径仍指向历史 CoreMark 镜像，不要用它覆盖刚在 GUI 选择的初值。

## 7. 验证结果与报告

```bash
python3 scripts/check_video_integration.py
python3 scripts/lint_video_platform.py
python3 scripts/audit_video_project.py
# 可选：额外核对本机原始参考文件
python3 scripts/audit_video_project.py --reference-root /mnt/c/Users/yyyyou71/Desktop/ziguang-fpga2
```

测试使用 Verilator 5.052，AI 参数始终为 0：

- 自有双发射 CPU 执行新固件，同时视频客户端读写 DDR；正常和随机等待各核对 512 个写拍和 512 个读拍，完成两轮 lease/release，并验证 CPU 越界未发出原生事务。
- mailbox：无帧错误、排除正在写的槽、保留信息稳定、帧号回绕、释放、重复获取、未就绪/故障及复位。
- 帧写控制器：保留槽的数据/帧号不被覆盖，环绕跳过保护槽，全池保护时不发 AW，释放后恢复；使用测试专用 FIFO 延迟模型。
- 尺寸/周期监测：真实 1920×1080 像素计数、帧周期变化、短行/短帧拒绝、恢复与复位。
- 结构 lint：从实际导入包装抽取真实端口作黑盒，核对物理顶层连接。没有错误及 MULTIDRIVEN/LATCH/UNOPTFLAT/SELRANGE/IMPLICIT；参考宽度/不完整 case 等告警保留在报告中。
- 静态审计：PDS 文件存在/无重复/分组平衡，目标器件、管脚覆盖和冲突检查，以及 Acore/IIC 和参考源文件 SHA 核对。

以上短测针对新增连接，**不代表厂商 PHY 仿真、综合、实现或实板验收**。
PDS 工程打开已在本机图形界面单独确认；命令行 Compile 检查未完成，见文首修复记录。
没有重新运行 AI 回归、完整网络、CoreMark 或带宽评估。

| 内容 | 路径 |
| --- | --- |
| 新增逻辑功能结果 | `reports/video_integration/functional.json` |
| 物理顶层结构检查 | `reports/video_integration/structural.json` |
| PDS/管脚/IP/来源审计 | `reports/video_integration/project.json` |
| PDS 原生界面打开确认与编译检查限制 | `reports/video_integration/pds_project.json` |
| 详细短测日志 | `build/video-integration/`（忽略目录） |
| 用户 PDS 实现后的资源 | `place_route/acore_dual_top.prr` |
| 用户 PDS 实现后的时序 | `place_route/acore_dual_top.rtr` |
| hold 修复后摘要 | `place_route/acore_dual_top_timing_summary_after_hold_fix.txt` |
| 用户生成的新位流 | `generate_bitstream/acore_dual_top.sbit` |

资源和时序必须看本次实现时间戳；历史 CoreMark 报告不代表 HDMI/PCIe/DDR 系统的资源占用。

## 8. 后续仍需完成的部分

下一阶段在原始 RGB888 分支实现与模型导出一致的 96×96 池化/通道格式化，并使输入张量和锁定原图共享 frame_id。
之后接既有 AI 算子/调度/后处理、原图坐标映射与 RGB565 画框，最后接 RK 控制/模型加载/结果协议。
`pango_ai_multadd` 目前只有待生成 IDF，实际 AI 启用仍须生成厂商 IP 并核对延迟；本轮不把行为模型用于硬件。
SPI 和 RK 软件协议按用户指示暂缓，不擅自分配引脚、速率或消息格式。
