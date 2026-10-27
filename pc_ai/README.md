# PC 端模型推理与训练工具

日期：2026-10-26。PC 端环境、推理、后续训练入口和使用说明统一放在本目录。

## 目录

```text
pc_ai/
  environment.yml          Conda 环境定义
  requirements-cpu.txt     CPU 推理依赖版本
  check_env.py             快速环境检查
  verify_trident.py        参考整数模型检查、输入准备、推理和画框
  trident_infer_bridge.c   调用参考 C 模型的桥接入口
  outputs/                日志、输入、推理结果和临时程序，不提交 Git
```

硬件仿真脚本仍由工程的测试系统管理。本目录不存放复制出来的第三方工程、训练集或大权重。

## 当前环境

使用已有 Anaconda 的独立环境 `yolo-fpga`，保留 base、ros_env。
用户已完成安装和快检：Python 3.12.15、PyTorch 2.13.0+cpu、torchvision 0.28.0+cpu、Ultralytics 8.4.115，依赖导入和基础张量运算通过。
当前是 CPU 推理环境；机器存在 NVIDIA PCI 设备，但 GPU 驱动和 CUDA 训练尚未配置。
先前重复的项目内 `.venv-yolo` 已删除，Conda 环境保留。

已有环境直接使用：

```bash
conda activate yolo-fpga
python pc_ai/check_env.py
```

新机器安装需要等待，由用户运行：

```bash
source ~/anaconda3/etc/profile.d/conda.sh
cd pc_ai
conda env create -f environment.yml
conda activate yolo-fpga
python check_env.py
cd ..
```

已有环境需补依赖时，在工程根目录运行 `python -m pip install -r pc_ai/requirements-cpu.txt`。
快检只做依赖导入和小张量计算，不下载权重、不启动完整推理或训练。
结果保存在 `pc_ai/outputs/environment/environment.json`。
Ultralytics/Matplotlib 配置目录会先在 outputs 内创建，避免不存在的父目录触发回退到 /tmp。

## 第一个参考工程的资产情况

- 读取 `../materials/TridentVision/training/export/rearch_int8.bin`，不修改材料目录。
- 本地没有 `.pt/.pth` 检查点，暂不能恢复该工程的训练，也不能声称已验证其浮点模型。
- 导出报告指向 `color7c_qat`，评估脚本提供红、橙、黄、绿、青、蓝、粉七种名称。
- 网络检测头有 80 个类别输出通道，但这不能证明附带二进制能做 COCO 通用检测。
- 当前先验证其对七色色块的实际响应；名称与权重的对应关系仍需检测结果确认。

## 推理验证：由用户运行完整网络

从工程根目录执行：

```bash
conda activate yolo-fpga
python pc_ai/verify_trident.py --run
```

该命令会运行两次完整的 72 卷积层整数网络，可能需要等待；代理不代为启动长任务。
它不训练模型、不下载权重，也不调用 FPGA。
不带 `--run` 时，只检查资产、生成输入并编译 C 入口，适合快速准备：

```bash
python pc_ai/verify_trident.py
```

默认准备两张诊断图：七个已知颜色的大矩形，以及没有目标的深色背景。
输入将 RGB 按 adaptive average pooling 的整数边界降到 96x96，均值最近舍入为 0..255 像素码，使用 CHW INT16、尺度 1/255。
此处整数舍入与训练时连续浮点池化存在小差异，也不等于已核对实板 pool_feed 的全部像素语义。

可额外输入自己的实拍图片：

```bash
python pc_ai/verify_trident.py --run --image /绝对路径/照片.jpg
```

也可以直接输入整个图片目录，递归读取子目录、自动去重：

```bash
python pc_ai/verify_trident.py --run --image pc_ai/picture --out pc_ai/outputs/trident_real
```

不要求 JPG 后缀；由 Pillow 按文件内容识别，可读取的 JPG/JPEG、PNG、BMP、TIFF、WebP、GIF 等都可以。
多帧图只用首帧；手机照片按 EXIF 修正方向，透明图片在白底合成。
不支持的格式、非图片和损坏文件会跳过，原因记入输出目录的 `skipped_images.json`；全部不可读时停止并说明。
具体解码能力取决于当前 Pillow 安装，不承诺无需额外解码器就支持所有 HEIC/RAW 等格式。
每张照片使用 `photo_序号_原文件名/` 子目录保存结果；`cases.json` 和 `result.json` 记录原图路径。
目录批次仍包含两张默认诊断图；多张图完整推理需要等待，由用户执行。准备阶段不加 `--run`。

输出位于 `pc_ai/outputs/trident_validation/`：

- `asset_audit.json`：权重哈希、头部数量、位宽和检查点清单。
- `cases.json`：输入、预处理及默认诊断图标注。
- `seven_colors/detections.png`、`blank/detections.png`：画框结果。
- 各用例的 `raw.json`、`infer.log`、`first_conv.bin`：完整候选框、日志和第一层输出。
- `result.json`：候选数量、诊断匹配统计、第一层独立对拍结果及运行时间。

C 桥接复用原始整数前向和后处理，输出全部候选框，不改第三方源文件。
第一层另外使用 NumPy 独立归约，按参考模型的 Q13 偏置、round-half-up、ReLU、INT16 饱和逐项比较。
该舍入与当前 FPGA 引擎的半整数远离零规则不同；验证通过也不代表可直接加载到现有 W8A8 硬件。

程序完成只表示整数前向和第一层独立对拍通过；其余层尚未独立逐项对拍。
合成图的 IoU/匹配统计是诊断数据，不是测试集 mAP，也不能证明实拍识别精度。
先查看画框和统计，再决定这份模型是否值得移植；不会把“输出了 300 个候选框”当作“检测成功”。

## W8A16 RTL：以原 C 卷积作为数值参考

从工程根目录执行：

```bash
make test-conv2d-w8a16
# 只准备向量和编译，不启动仿真：
python3 pc_ai/verify_w8a16_rtl.py --prepare-only
```

只需本机 GCC、Python 标准库、Icarus Verilog 和 Verilator，不依赖 Conda、PyTorch 或 NumPy。
`w8a16_vectors.c` 直接包含材料目录的 `rearch_fixed.c`，读取现成权重，调用其 `conv_layer`。
使用全部 72 份真实卷积记录及 12 种补充配置，在独立 5×7 输入张量上生成参考结果。
每种配置抽取角点、另一角点及中间位置，共 252 个输出块；每块最多 4 通道。
Python 只编译、启动、检查退出状态和整理报告，不另写完整 Python 网络，也不充当数学期望值来源。

量化边界另用 C `__int128` 生成 634 个向量，覆盖超过原 C int64 中间乘积范围的边界。
仿真额外执行量化 3 次复位重放、卷积 2 次复位重放，并检查暂停、反压、非法配置和缓存重新装载。
输出保存在 `pc_ai/outputs/w8a16_rtl/`，详见 `result.json`、`cases.json`、各项日志和 `.mem`。

这里验证的是新计算块，尚未接入 DDR/MMIO，也不是 72 层连续网络推理或上板结果。
参考卷积的输入是合成张量；不能把使用真实权重的算子对拍当成真实图片检测精度测试。
接口、数值规则及后续集成边界见 [W8A16 计算块说明](../docs/conv2d_w8a16_core.md)。

## W8A16 DDR与CPU连续两层

```bash
make test-conv2d-w8a16-ddr
# 增加随机停顿、零读写延迟、不同CPU/DDR频率组合：
python3 pc_ai/verify_w8a16_ddr.py --profiles all
# 只准备输入、C期望值、固件和仿真程序：
python3 pc_ai/verify_w8a16_ddr.py --prepare-only
```

输出位于 `pc_ai/outputs/w8a16_ddr/`，`engine/` 是12种独立层配置，`cpu/` 是原C网络前两个卷积的连续计算。
DDR向量由 `w8a16_ddr_vectors.c` 调用原始C卷积生成；不经过Python数学参考。
12种独立层中的8种使用真实权重/量化记录的输出通道子集，另外4种是补充配置，不是12层连起来的网络。
CPU测试则保留原 `model.0`、`model.1` 的完整32/64输出通道，输入是5×7合成RGB张量。
CPU读取DDR中的描述符并配置寄存器，第二层直接使用第一层INT16输出；最终通过CPU窗口及测试台分别核对结果和填充区。
模型资产由测试台模拟外部传输端预装DDR，尚未接SPI，也不是CPU在做逐元素卷积。

此测试需要 `riscv64-unknown-elf-gcc`；新固件指令区为976字节，没有将参数编入ROM。
默认DDR模型用户时钟周期7.619ns（约131.25MHz），不是CPU的25MHz时钟。
`--profiles all` 还验证CPU约71.43MHz/DDR约166.67MHz，以及CPU约166.67MHz/DDR80MHz。
仅补充这两组时钟检查可用 `--profiles clocks`，结果另存 `clocks_result.json`，不覆盖主要 `result.json`。
另有 `--grouped-cpu --out pc_ai/outputs/w8a16_ddr_groups`：将第二层变成补充的两尺度配置，检验非零AI_GROUP的跨域传递；它不是原网络第二层的等价替换，输出也独立保存。
仿真时钟可运行不表示相应物理频率已经时序收敛。
完整寄存器、32字节量化记录及上板边界见 [W8A16 DDR与CPU接口](../docs/conv2d_w8a16_ddr.md)。

## W8A16通用模型包与任务表

```bash
make test-ai-tasks-w8a16
python3 pc_ai/verify_w8a16_tasks.py --prepare-only
# 需要更多时钟组合时，由用户执行等待：
python3 pc_ai/verify_w8a16_tasks.py --profiles all
```

`export_w8a16_tasks.c`调用原C卷积导出三种小网络的资产和逐层期望值。
统一的`pack_ai_model.py`支持`activation_bits=16`，生成版本2模型包、64字节任务和32字节量化记录。
CPU查询硬件位宽，同一份固件识别版本1/2；模型权重和任务仍全部在DDR。
Python不计算W8A16卷积期望值，`--reference`只保留给旧W8A8格式。

默认定向测试已通过：一次运行26次模型请求、15次AI提交，核对11403个DDR字；最初固件3080字节，加入ADD后统一固件3444字节，初始化数据段为0。
包含两层、三层、两尺度分组、引用较早层输出、22种错误及不复位恢复；另验证原生FAULT停止、8位硬件拒绝16位模型。
这不是完整YOLO推理。资产由测试台模拟外部加载端预装DDR，SPI和板级时序仍待集成。
输出集中在`pc_ai/outputs/w8a16_tasks/`：`network*.json`、资产、期望值、模型包、manifest、固件、仿真程序及日志。
默认只运行CPU25MHz/DDR用户时钟约131.25MHz；扩展组合的执行情况以`result.json`为准。
字段说明和正式打包命令见 [DDR任务表](../docs/ai_task_runtime.md)。

## 残差ADD：两张特征图相加

```bash
make test-ai-add
python3 pc_ai/verify_w8a16_tasks.py --suite add --prepare-only
```

ADD先把两路特征值按各自尺度换算，再相加写回DDR，后续卷积可以直接读取。
`export_add_tasks.c`调用参考C的`add_point`和`conv_layer`，复用原导出工具，生成ADD单元、独立DDR及残差网络测试。
输出集中在`pc_ai/outputs/add_tasks/`；969个单元向量及复位重放、15种DDR配置、三种CPU任务网络已通过。
CPU测试一次处理22次模型请求、18次AI提交，核对6717个DDR字，包含卷积→ADD→卷积及分支数据复用。
单位计算、DDR停顿/零延迟、参数错误、FAULT和复位恢复均有覆盖；默认CPU任务时钟仍是25MHz/DDR约131.25MHz。
更多CPU时钟组合可运行`python3 pc_ai/verify_w8a16_tasks.py --suite add --profiles all`，执行情况以报告为准。
模型JSON使用`op="add"`、`input`、`input_b`和`quant_add=[MA,SA,MB,SB]`，两输入形状必须相同。
完整接口与简单数据流见 [ADD说明](../docs/add_int16.md)。

## 通道拼接Concat与完整C3模块

```bash
make test-ai-concat
python3 pc_ai/verify_w8a16_tasks.py --suite concat --prepare-only
```

把A、B每个像素的有效通道接起来，不把输入尾部填充接进结果，不做量化，最终输出尾部补零。
`export_concat_tasks.c`复用导出工具，期望值直接调用参考C的`concat2`、`add_point`和`conv_layer`。
输出在`pc_ai/outputs/concat_tasks/`：16种DDR配置、正常/停顿/零延迟及缓存复用检查通过。
CPU一次运行22次模型请求、19次AI提交、8977个DDR字；包含完整参考C3块的7条任务、5+17通道拼接后接卷积及重复拼接。
当时统一固件3856字节，仍未运行完整YOLO，也未综合上板。
更多CPU时钟组合可由用户运行`python3 pc_ai/verify_w8a16_tasks.py --suite concat --profiles all`，以报告记录为准。
JSON使用`op="concat"`、`input`、`input_b`；两路高宽须相同，通道数可不同。
两路量化尺度的限制、寄存器语义和缓存数据流见 [Concat说明](../docs/concat_int16.md)。

## 5×5最大池化与完整SPPF模块

```bash
make test-ai-maxpool
python3 pc_ai/verify_w8a16_tasks.py --suite maxpool --prepare-only
```

固定5×5、步长1、填充2，逐通道取有符号INT16最大值，输出形状和尺度不变。
每次处理一个DDR字的8通道，只保存当前窗口最大值；不需要整图片上缓存或RAM IP。
`export_maxpool_tasks.c`调用参考`maxpool5`等原C函数，生成16种DDR配置及完整SPPF/卷积前后连接/连续池化三种CPU网络。
正常、随机停顿、零延迟、边界/填充、复位和读写故障测试通过。
CPU一次处理23份模型请求、15次AI提交、17020个DDR字；统一固件4104字节、初始化数据段0字节。
输出位于`pc_ai/outputs/maxpool_tasks/`，更多时钟组合可由用户执行`python3 pc_ai/verify_w8a16_tasks.py --suite maxpool --profiles all`。
JSON使用`{"name":"pooled","op":"maxpool5","input":"previous_layer"}`，任务操作码4，仅支持版本2。
接口、数据流与当前重复读取邻域的取舍见 [MaxPool5说明](../docs/maxpool_int16.md)。
随后已完成下节2倍最近邻上采样；完整检测网络、综合与上板仍待完成。

## 2倍最近邻上采样与五类算子混合任务

```bash
make test-ai-upsample
python3 pc_ai/verify_w8a16_tasks.py --suite upsample --prepare-only
```

每个INT16像素复制到2×2区域，H/W各翻倍、C不变；输出占用输入四倍空间。
每个有效16字节源字只读一次、复用四次写入，片上只保存当前源字；尾部填充显式清零。
`export_upsample_tasks.c`调用参考C，导出16种DDR配置和三种CPU网络：五类算子混合、上采样后接真实两尺度卷积、连续两次上采样。
DDR正常/停顿/零延迟、维度/容量/重叠检查、读取或复制中复位、原生读写超时均通过。
CPU一次处理28份模型请求、14次AI提交、18252个DDR字；统一固件4244字节、初始化数据段0字节。
输出在`pc_ai/outputs/upsample_tasks/`，默认CPU25MHz、DDR约131.25MHz；扩展组合可由用户运行`python3 pc_ai/verify_w8a16_tasks.py --suite upsample --profiles all`。
JSON使用`{"name":"up","op":"upsample2x","input":"previous_layer"}`；输入H/W为1..32767、C为1..65535，任务操作码5，仅支持版本2。
说明见 [上采样接口与验证](../docs/upsample_int16.md)。下一步导出真实全网任务表并分段对拍，检测后处理、综合和上板仍待完成。

## 长任务约定

安装、下载、完整网络推理、训练等预计需要等待的命令，先说明用途，由用户执行。
代理处理短检查、脚本准备、结果分析与已授权的RTL修改；当前不启动训练。
