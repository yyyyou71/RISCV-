# HDMI 抓帧超时诊断

本改动位于 `ziguang_rv32i`，基于 `15c1e4f`。SPI 图片输入方案保存在
`codex/spi-image-input` 的 `a5f6320`，未合并到 HDMI 分支。

## 目的与边界

上板日志测到 1919×1080、60 Hz，DDR_READY=1、FAULT=0，但 RAW 获取帧超时。
这些信息不能区分 FIFO 后帧头丢失、DDR 写入未完成和帧完整性检查不通过。
本版只增加观察和读取功能，不改变补黑、帧头识别、DDR 握手、完整帧发布条件、
帧槽所有权或超时时间；尚不能宣称原故障已修复。

## 上板操作

### 软核流程监测（1 秒采样）

软核自动采样硬件写帧计数，不阻塞等待快照；约每秒输出一行 `[pipeline]` 日志，
阶段变化时也立即输出。随时查询当前阶段及保留的故障前状态：

```sh
sudo ./rk_comm_cli /dev/spidev4.0 video-debug
# 或持续读取每秒日志，Ctrl+C 退出后再运行其他 SPI 客户端：
sudo ./rk_comm_cli /dev/spidev4.0 listen
```

阶段包括：等待 DDR、等待输入帧头、等待 FIFO 后帧头、等待首次 DDR 写入、
写入中等待完整帧发布、等待软核取得帧、等待张量、张量格式检查、帧已保留、
模型上传、AI 任务执行/后处理、画框准备、等待 PCIe 链路/发送完成、发送完成、失败。
RK 显示中文解释及原始计数；RAW 模式不会出现 AI 推理阶段。

`observed` 是本轮抓帧期间观测到的活动标志，其分辨率约为 1 秒，不能证明逐像素正确，
也不是每个视频帧的精确轨迹。短暂阶段可能跨过两次采样，但累计计数仍能显示活动。
`WAIT_PCIE_DMA_COMPLETION` 不能区分“RK 尚未启动 DMA”和“DMA 正在传输”；
`PCIE_DONE` 也不代表 RK 窗口已经成功显示。

失败时保存最后观测阶段和最近一份硬件快照，后续采样不覆盖它；重新抓帧或复位才清除。
输出包含快照年龄，从发起硬件快照请求的 CPU 周期计算，可能距错误约 1 秒，
不能当作故障发生那个时钟周期的波形。
硬件诊断缺失/不响应会单独显示，软件仍处理其他 SPI 命令，不会一直卡在诊断读取。

新增命令 20 `COMM_VIDEO_DEBUG` 返回 52 字（208 字节）：
0 ABI；1 当前阶段；2 失败前阶段；3 软件视频状态；4 错误阶段；5 RAW/AI；
6 阶段驻留周期；7 当前周期；8 有效/请求中/诊断异常/失败已保存标志；
9 快照年龄；10 快照序号；11 已观测活动位图；12 帧号；
13..16 AI 状态/错误/当前任务/总任务；17..19 回传状态/错误/硬件状态；
20..21 预处理状态/错误；22..23 原始宽高/帧周期；24..35 当前硬件快照；
36..47 错误前快照；48 错误前快照标志；49 错误前快照年龄；
50 距最近观测到写入活动变化的周期；51 诊断错误（1=超时，2=签名不符）。
此命令仅用于本 HDMI 分支。命令 19 `video-writer` 也改为读取最近的缓存快照，
其年龄最多约 1 秒；启动后还没有快照时可能返回 BUSY。

### 更新和抓帧检查

重新编译根目录 `rv32I.pds` 并烧录新位流；根工程 ROM/RAM 已选择本版
`video_diagnostic` 固件。只更新 RK 程序不能获得新硬件计数。

将本分支 `csrc/rk_fspi` 整个文件夹复制到 RK，在 RK 原生编译：

```sh
cd ~/workspace/rk_fspi
make clean
make all
sudo ./rk_comm_cli /dev/spidev4.0 video-status
sudo ./rk_comm_cli /dev/spidev4.0 video-debug
sudo ./rk_comm_cli /dev/spidev4.0 video-writer
sleep 2
sudo ./rk_comm_cli /dev/spidev4.0 video-writer
```

先退出 `rk_video_app`，避免两个程序同时占用 SPI。`video-writer` 即使抓帧已经
进入 ERROR 也可读取，不会重启抓帧或复位 DDR。

## 读数解释

| 字段 | 含义 |
|---|---|
| pixel_SOF | 像素域整形模块实际输出的帧头累计数，经 Gray 编码同步 |
| decoded_SOF | FIFO 后写控制器识别到的帧头累计数 |
| completed_bursts | 写控制器收到 WREADY 与 WLAST 的累计突发数 |
| published / rejected | 上一帧被发布或未通过发布条件的累计次数 |
| last_frame_bursts / expected | 上一个已结束帧的突发数 / 目标值，1080p 目标为 16200 |
| current_bursts | 正在处理帧已完成的写突发数 |
| last_invalid / last_dropped / last_source_fault | 上一帧结束时的无效、无空闲槽丢帧、输入溢出标志 |
| state / FIFO_words128 | 写状态机和 FIFO 水位，水位单位为 128-bit 字 |
| last_burst_head | 最近一次从 FIFO 装载的突发首字低 32 位，辅助定位帧头所在 lane |
| available / protected | 已发布帧槽 / 受保护帧槽位图 |

计数从 FPGA 复位起累计，32 位自然回绕；需要对比两次快照的增量。
pixel_SOF 与 decoded_SOF 存在流水线延迟，单次相差 1 不等同于丢帧。

* pixel_SOF 不增长：检查整形模块的输入时钟、复位、VS/DE。
* pixel_SOF 增长而 decoded_SOF 长期不增长：检查 FIFO 打包顺序、读延迟、帧头位置。
* decoded_SOF 增长，但 last_frame_bursts 不等于 expected，且 rejected 增长：
  检查每帧像素数量、帧边界和写突发完成数量。
* state 长期停在 WAIT_AW 或 WRITE_DDR，completed_bursts 不增长：检查 DDR 请求和响应。
* published 增长且 available 非零，但仍无法领取：检查 frame_mailbox 与帧槽保护逻辑。

这是定位方向，不是对实际板卡故障原因的预判。
RAW 模式的 video-status written_bytes 固定为 0；它不是 DDR 写入字节计数。

## 接口

复用现有预处理 MMIO 页中的空闲空间：0x309c0 写 1 发起快照，读 bit0=BUSY、
bit1=VALID；0x309c4..0x309f0 保存 12 个只读字。DDR 域冻结整组数据后返回 ACK，
CPU 域等双级 ACK 同步完成再锁存，避免直接跨域读取变化的计数。
数据第 0 字固定为 0x56444731（VDG1）。只有请求/ACK 和 Gray 计数同步器的第一级
设置异步例外，快照数据路径继续受现有最大延迟约束。

新增 SPI 命令 19，`COMM_VIDEO_WRITER_STATUS`，返回 ABI 0x00010000 和 12 字硬件快照。
本命令仅适用于 HDMI 分支，不能与 SPI 图片分支命令 19 混用。
原 video-status、RAW/AI 模式、检测结果协议保持不变。

## 验证

`python3 scripts/check_video_writer.py` 检查短帧拒绝、完整帧发布、累计计数、
跨时钟快照一致性和复位。`scripts/check_video_modes.py` 检查 RK 客户端及软核控制流程。
综合报告位于 `synthesize/acore_dual_top.snr`；实现后的资源和时序报告位于
`place_route/acore_dual_top.prr` 与 `place_route/acore_dual_top.rtr`。

2026-11-03 原始硬件诊断版短测试、RK 客户端测试、软核模式检查、顶层结构检查及 PDS 综合通过。
综合估算：LUT 39977/66600（60.03%），FF 35584/133200（26.71%），
DRM 87.5/155（56.45%），APM 21/240（8.75%），锁存器 0。
未运行本版布局布线，未生成新位流，尚无本版时序收敛和实际抓帧通过的结论。
以上综合结果对应增加流程监测之前的固件，不代表更新后固件已重新实现。
详细验证记录见 `reports/video_integration/hdmi_writer_validation.json`；
流程监测的软件检查记录见 `reports/video_integration/raw_ai_modes_checks.json`。
