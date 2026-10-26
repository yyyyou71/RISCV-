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

## 长任务约定

安装、下载、完整网络推理、训练等预计需要等待的命令，先说明用途，由用户执行。
代理处理短检查、脚本准备、结果分析与修复；当前不启动训练、不修改 AI RTL。
