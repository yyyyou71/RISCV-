# P3b：纯 SPI 模型加载、99 任务和 CPU 检测后处理

当前根 rv32I.pds 仍使用自己的双发射 Acore，25MHz，W8A16，唯一物理 DDR3。
本阶段只改软件/ROM/RAM 初始化，没有改 CPU、AI、HDMI、DDR 或 SPI RTL。
FPGA 可独立上板，RK 暂缺联调条件：以下控制链路已接入并做软件检查，不能称为 RK/FPGA 整网板测通过。

## 当前默认行为

ROM/RAM 仍选择 firmware/video_diagnostic/，加入了完整模型服务。
没有 RK 时，启动继续执行原视频自检和真实第 1 层自检；没有模型不会启动 99 层推理。
此前 HDMI 尺寸错误尚待硬件诊断，未因这次软件修改而认定已解决。
完整模型先通过 RK 加载，随后显式 infer；不会因接收到部分权重就启动计算。

FPGA 接收 13,372,720-byte 镜像，从 AI 逻辑 DDR 字节地址 0 开始，
存放请求/后处理区、任务、权重、量化、输入占位和特征图工作区。
原图仍在物理低 64MiB，AI 逻辑地址统一平移到物理高 64MiB，没新增 DDR PHY。
加载器最多允许低 32MiB，不会覆盖高地址预处理张量和首层自检区。
每块 16 字节对齐，最多 224 字节；完整 SPI 包校验后，CPU 写 DDR 并逐字回读才确认进度。
整包 FNV-1a、长度、AIM1/AIP1 头/profile 检查通过才设置模型就绪。
99 条任务的完整形状/地址预检继续由原运行时在启动任何算子之前完成。

HDMI 已持有原图/张量后，infer 排队执行 99 任务，再调用已有定点检测后处理。
只把任务中精确引用原模型输入的读指针绑定到 0x03f00000 的已保留张量，
保留 DDR 中的原始模型/描述符，也不由 CPU 复制整张 294,912-byte 图像。
覆盖 CONV 与二元 ADD/Concat 的输入引用，拒绝越界、尺寸不符和不支持的子区域引用。
六张输出头仍按三组 box/cls 读取，原有两次稳定 Top-K、阈值和定点规则不变，没有新增 NMS/OCR。

运行时在 DDR 等待、算子等待及后处理 DDR 访问间继续轮询 SPI。
允许读取进度，拒绝改模型、重新运行和释放帧；保留 frame_id、raw slot、model session 和 run_id。
每层软件看门狗 60s；超时不强行复位或抢占硬件 DDR 事务。
若窗口仍 BUSY/FAULT，继续限制写入/释放，需要等待事务结束或协调板级共同复位。
32位硬件周期累计沿用原 ABI；另用 CPU 64位累计周期记录整次运行时间。

## 模型文件准备

本机已经生成 build/board-ai/board_model.bin，文件和校验见同目录 board_model.json。
大文件留在忽略的 build 内，不随 Git 提交；本次准备包没有计算整网黄金结果或启动推理。
从已有 prepared/model.bin、heads.json 重新打包：

```sh
python3 scripts/prepare_board_model.py
```

若该临时 prepared 目录不存在，先从自己的 TridentVision 资产导出（不加 --golden/--run）：

```sh
python3 pc_ai/prepare_trident_network.py --reference /path/to/TridentVision --out build/integration-review/model_prepared
python3 scripts/prepare_board_model.py
```

threshold 默认 Q0.16 16384（0.25），可在打包时用 --threshold 调整。
模型头地址固定 0x10000，AIP1 在 0x5000，三组头在 0x5100，LUT 在 0x5200，检测记录在 0x8000。

## RK 恢复条件后的使用步骤

1. FPGA 重新打开根 PDS，从 Compile/综合开始生成新位流并烧录。
   ROM/RAM 初始化已更新；旧位流不会自动包含新服务。
2. 整个 csrc/rk_fspi 源码文件夹复制到 RK，再把 board_model.bin 也复制进去。
   RK 本机已有 GCC/make 时执行：

```sh
make clean
make all
./rk_model_cli /dev/spidev4.0 load board_model.bin
```

3. 重新抓当前视频帧，先确认 video-status 为 SUCCESS_HELD。
   加载期间暂停视频状态机，防止 CPU DDR 窗口被两个任务同时配置。

```sh
./rk_comm_cli /dev/spidev4.0 video-retry
./rk_comm_cli /dev/spidev4.0 video-status
./rk_model_cli /dev/spidev4.0 infer
```

4. infer 返回 QUEUED 只是接受请求。监听或查询进度，直到 DONE：

```sh
./rk_comm_cli /dev/spidev4.0
# Ctrl+C 后再运行其他命令
./rk_model_cli /dev/spidev4.0 status
./rk_model_cli /dev/spidev4.0 results
```

结果以文本/CSV 打印类别 ID、置信度、96×96 模型坐标，以及映射裁剪到 1920×1080 的坐标。
这仅是 RK 文本显示坐标，FPGA 流式画框与 PCIe 图像输出仍待 P4。
DONE 且零条检测是合法结果；不能把当前资产的类别数等同于已验证的通用检测准确率。

所有客户端独占 SPI，不能让监听和加载/查询并行运行。IIC 不参与。
底层继续 50MHz、Mode3、单段 directional quad、payload-only，SPT1 固定 256 字节帧。
CPU 在发布响应前保证下一 RX 已 ARM，批量工具以响应作为后续请求信用，
不会为每个模型块重新等一秒的 READY 通知。
终端仍自动打印 [video]、[ai]、[network]，可单独用 network-status 查询。

## 断传和所有权

驱动短传输/校验错误后不自动重放有副作用的命令。
保留已提交字节位置，可先 status，再显式 resume 同一文件：

```sh
./rk_model_cli /dev/spidev4.0 status
./rk_model_cli /dev/spidev4.0 resume board_model.bin
./rk_model_cli /dev/spidev4.0 abort
```

resume 要求仍在 LOADING，长度和整包校验匹配；从 CPU 回报的已确认位置开始。
最后一个已确认块允许完全相同的数据显式重复，数据不同或偏移不连续则拒绝。
abort 只取消软件模型状态，不抹 DDR，也不取消已接受的硬件事务。
模型失效后 infer 被拒绝；板级复位清就绪状态，必须重新加载。
加载期间和运行期间都阻止释放/换帧。结果请求携带 session/run_id，防止读取另一任务的结果。
video-retry/release 在可执行时清旧结果有效性，但保留已加载模型。

## 线协议扩展

SPT1/RVC1 的旧命令编号不变。新增请求 payload 均为小端：

| 操作 | 编号 | 请求 |
| --- | --- | --- |
| begin | 9 | session、镜像总长度、整包 FNV、模型 tag，各 u32 |
| chunk | 10 | session、字节 offset、16..224 字节数据 |
| commit | 11 | session |
| status | 12 | 空 |
| infer | 13 | session |
| detections | 14 | session、run_id、起始条目、条数（1..6） |
| abort | 15 | session |

自动 network 消息类型 0x8005。状态负载 28 个 u32：
ABI/state/error/session/tag/received/total/hash/expected/run_id/frame_id/task_count/completed/
failed_task/hardware_code/engine_cycles/issues/post_code/detection_count/post_read_calls/
current_task/elapsed_lo/elapsed_hi/flags/input_base/raw_slot/result_addr/source_shape。
flags bit0模型就绪、bit1窗口FAULT、bit2窗口BUSY、bit3预处理FAULT。
状态 0..7：EMPTY/LOADING/READY/QUEUED/RUNNING/POSTPROCESS/DONE/ERROR。
错误 0x1001=装载DDR读写或回读不符，0x1002=整包校验不符，0x1003=板级模型头不符；
网络/后处理沿用 AI runtime code。结果响应是六个元数据 u32 + 原 ABI 每条32字节记录。

## 验证和未完成项

固件 GCC10.2/O2/RV32IM -mno-div；当前 text=23,572 bytes、data=6,718 bytes、BSS=2,044 bytes，
链接脚本为后处理预留至少16KiB栈，GCC 的后处理固定帧记录为5824字节。
RK 工具只在 WSL x86 上编译和 mock，不是已编出的 ARM 程序，也不是 RK 现场结果。

```sh
python3 scripts/check_board_network.py
```

该命令只做短软件检查：上传回读/重复块/结果归属、主机续传与无自动重放、
实际运行时的默认/绑定输入及范围预检。算子/DDR 控制由软件响应器替代，未执行网络数学或 RTL。
没有重跑已验证的全 AI 回归；没有完成 RK 联调、FPGA整网板测、PDS本轮综合/P&R或新位流。
本版没有改 RTL，FPGA 仍可单独运行 P3a 首层；完整网络需 RK 或等价加载端把大模型放进 DDR。
当前 LED 不提供整网正确性的证明，详细状态以之后的 SPI 查询为准。

检查和资产摘要见 reports/preprocess/board_model.json、network_software.json、network_integration.json。
资源/时序仍以用户本次 PDS 实现输出为准，位置与 P3a 相同。
建议提交：feat: 增加SPI整网模型加载与99任务检测服务。
