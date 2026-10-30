# P2：CPU 按需抓取 HDMI 张量与同帧原图

基线为合并后的 `0b32c29`，唯一工程入口仍是根目录 `rv32I.pds`，顶层为 `acore_dual_top`。
本阶段接入 P1 预处理，不启用 AI，不修改 SPI 的协议、引脚、服务固件或测试顶层。
当前已增加并默认启用不接 RK 的独立模式，应用复位和 LED 闪码说明以 `standalone_capture.md` 为准。

## 合并检查

- 对比 `8119922..0b32c29`，此前的 Acore 双发射、DDR 修复、全局时钟、PHY 约束和 P1 文件均保留。
- 未发现冲突标记；SPI 合并主要新增独立测试顶层、适配器和 MMIO 读数据选择。
- 主视频顶层尚未启用/引出 SPI；`board_fspi_top` 是队友使用的独立入口。
- SPI 文档已指出旧服务固件与视频并用的地址适配尚未完成；本阶段不修改该内容。
- 根工程 `groute_seed` 设置为 3。PDS 如果仍打开旧窗口，需在界面确认此值再保存。

## 活动数据通路

```text
Acore MMIO 0x30800 → hdmi_tensor_capture
  ├─ 原始 HDMI RGB888 → rgb888_pool96 → 16-bit 串行化 → 参考 FIFO IP
  │                                        → ddr_block_transfer → 张量 DDR
  └─ 视频写端 SOF/完成事件 → 同帧原图槽保留 → CPU 显式释放

DDR 外层仲裁：参考视频 / CPU及张量客户端
DDR 内层仲裁：CPU窗口及未来AI / 预处理张量
```

`hdmi_tensor_capture` 实例位于 `acore_video_platform.u_preprocess`，
CPU 接口经 `board_top → soc → peripheral_bus` 透传，默认只在活动主顶层启用。
独立 SPI 顶层的 `ENABLE_PREPROCESS` 保持默认关闭。

张量为 96×96×16，小端 INT16、HWC；RGB 三通道后补 13 个零，共 294,912 bytes。
复用已生成的 `fifo_2_ddr`（16-bit 写 / 128-bit 读）跨时钟传输，再以 256-byte 命令写 DDR。
没有将行为 FIFO 或 RAM 模型加入 PDS，也没有修改原 FIFO IP 的参数。
每次发出 DDR 命令前确认完整 16 拍可用，`ddr_block_transfer` 收齐后才发 AW，
因此原生接口没有 WVALID 也不会因像素端暂停而写入错误数据。

## 帧身份与生命周期

视频写端在像素域和 DDR 域分别对实际发出的 in-band SOF 计数，包括因槽位不足而主动丢弃的帧。
预处理在目标 VS 锁存“下一个视频帧号”，原图开始写入时按帧号匹配并保留实际选中的槽。
FIFO 溢出会置粘滞故障，使这两个计数器的对应关系失效；共同复位前不能发布有效配对。

发布条件同时满足：

1. 预处理形状和拍数检查通过。
2. 全部 18,432 拍已被 DDR 接收完成。
3. 同 ID、同槽的原图完成事件有效。

成功后原图槽和张量描述符保持到 RELEASE。即使 PCIe 读端清除 available，原图仍受保护。
再次 START 不覆盖正在保留的结果。输入异常、原图未获槽或失效、超时、DDR 故障均不发布有效张量。
失败可能留下部分 DDR 写入，软件必须只消费 DONE=1、ERROR=0、HELD=1 的结果。
已接受的原生 DDR 事务不会通过局部复位撤销；正常错误先收尾，致命总线错误要求共同复位。

PCIe 仍按原逻辑发送 RGB565 原图，不等待 AI 结果；P4 再接结果驱动的发送和画框。
原图保留参考工程的像素边界标记，预处理使用标记替换前的 RGB888 分支。

## MMIO（32-bit 对齐）

| 地址 | 名称 | 含义 |
| --- | --- | --- |
| 0x30800 | CTRL | 写 1=START，2=RELEASE，4=清 DONE/ERROR；BUSY 时忽略写 |
| 0x30804 | STATUS | bit0 BUSY、1 DONE、2 ERROR、3 HELD、4 DDR_READY、5 FAULT |
| 0x30808 | FRAME_ID | 成功后配对帧号 |
| 0x3080c | RAW_SLOT | 成功后原图槽 0..4 |
| 0x30810 | TENSOR_BASE | CPU/AI 区内的逻辑字节地址，默认 0x03f00000；忙或保留期间不可修改 |
| 0x30814 | TENSOR_SIZE | 固定 294912 |
| 0x30818 | ERROR_CODE | 见下文 |
| 0x3081c | WRITTEN_BYTES | 返回的完整 DDR 命令字节数 |
| 0x30820 | RAW_NATIVE_BASE | 原图原生地址，slot<<22；每个原始视频 burst 的起址仍按参考布局加 256 原生单位 |

错误码：1 地址/范围，2 原图无空槽，3 错过目标原图，4 原图不完整，5 超时，
6 DDR/共同复位故障，7 张量拍数/身份不符，8 已持有结果；0x10|P1错误码表示预处理错误。

张量地址须 256-byte 对齐，末端不得超过逻辑 64 MiB。默认占用逻辑
`0x03f00000..0x03f47fff`，对应物理 `0x07f00000..0x07f47fff`。
此范围须由固件为张量保留，其他 CPU/AI DMA 不应向其中写入。
硬件不提供 CPU 内存保护；后续模型分配器必须避开该区域，或在空闲时配置其他不重叠的地址。

## CPU 程序与上板

`firmware/preprocess_capture.h` 提供 START、查询描述符和 RELEASE 接口。
`firmware/preprocess_bringup.c` 等待 DDR 和实际 1080p 输入尺寸（给 HDMI 配置最多 2 秒），
抓一帧，读回张量首尾像素检查格式/补零，再保留结果。
成功后 LED1 的 RTL 输出每 0.5 秒翻转；独立模式失败时 LED0 给出阶段闪码，见 `standalone_capture.md`。
板上亮灭取决于 LED 极性，LED0 不证明预处理完成。

例子已编译为 `firmware/preprocess_bringup/` 中的独立 hex。
2026-10-30 按用户要求，当前 CPU ROM/RAM IP 已切换到该镜像并重新生成。
ROM 8,192 个字和 RAM 16,384 个字均从生成的 DRM INIT 常量解码后逐字核对通过；
除 INIT_FILE 外所有 IP 参数保持不变，记录在 `reports/preprocess/selected_firmware.json`。

```bash
python3 scripts/build_firmware.py --app preprocess_bringup --core acore_dual --image-dir firmware/preprocess_bringup
```

以后重新编译程序后，可用以下命令更新两个现有 IP 的初始化内容：

```powershell
python scripts/select_acore_firmware.py --image-dir firmware/preprocess_bringup
```

该脚本分别选择此目录的 `acore_dual_rom.hex` 和 `acore_dual_ram.hex` 并重新生成 IP。
加 `--verify-only` 可只核对已嵌入的数据，不运行 IP 生成或仿真。
`acore_dual_ram_bytes.hex` 仅供仿真，不用于 IP 初始化。原 SPI 镜像和原 CoreMark hex 均保留。
旧位流仍包含生成它时的程序；需重新打开根工程，从 Compile/综合开始重新生成位流再烧录。

## 验证范围

只运行本次新增集成的两个短测，未重跑 P1 全套模式、AI 引擎或 CoreMark：

- 一个完整 1080p RGB888 帧：核对全部 18,432 个 DDR 拍、连续物理地址和补零；
  混入 CPU/视频客户端的原生接口协议激励和 DDR 等待，模拟原图开始/完成事件；
  核对配对、保留、释放、错误地址、原图丢弃和畸形输入。这不是整板 CPU/PCIe 联合仿真。
- 小尺寸真实视频写控制器：检查 SOF 帧号跨环绕、全保护丢帧及恢复仍对应，原有槽位保护有效。

结果在 `reports/preprocess/integration.json`，结构检查在 `reports/video_integration/structural.json`。
根工程 Compile 和原生综合均已通过，9 条新增同步首级约束均各匹配 1 个对象。
该综合记录对应切换固件前的初始化内容，切换后必须重新构建。
综合统计：20,514 LUT、20,536 FF、846 Distributed RAM、74.5 DRM、4 APM，
记录在 `reports/preprocess/synthesis.json`，原始报告为 `synthesize/acore_dual_top.snr`。
综合估计的本域 setup 余量：CPU +17.571 ns、DDR +1.340 ns、像素 +1.526 ns。
综合阶段 PHY hold 估计仍有负余量，必须经过真实布线与 hold 修复后再检查最终报告。
最终布局布线、位流生成和板级验收由用户执行。
旧 DDR 阶段的时序/位流不能代表加入 P2 后已收敛。
新实现后运行 `python3 scripts/audit_video_build.py`，结果写入 `reports/preprocess/implementation.json`。
PDS 原始资源和最终时序仍看 `place_route/acore_dual_top.prr`、`place_route/acore_dual_top.rtr`。

建议本阶段提交消息：`feat: 接入CPU控制的HDMI预处理与DDR同帧保留`。
后续进入 P3：AI 输入/权重调度、算子运行和 CPU 后处理；SPI/RK 加载协议等待队友联调。
