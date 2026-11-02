# FPGA 自定义 YOLO26 人脸检测训练

目标是**找出人脸并画框**，类别 0 为 `face`。不包含身份识别、五官关键点或人脸比对。
训练工具可在本机 NVIDIA GPU 或能执行自定义 PyTorch 脚本的云 GPU 上使用。
平台的数据/标注可以使用；平台内置的标准 YOLO26 一键训练不能自动保证与此 FPGA 结构兼容。

## 保持什么部署契约

- 仍是 TridentVision REARCH-v1：ReLU、双 3×3 Bottleneck 的 C3、一次池化带残差的 SPPF、普通卷积检测头。
- 输入 96×96 RGB，三尺度 12×12 / 6×6 / 3×3；`reg_max=1`，部署 one2one，无 DFL、深度卷积或注意力。
- 仍有 72 个部署卷积、10 ADD、14 Concat、1 Pool、2 Up，共 99 个任务；W8A16 量化。
- **保留 80 个物理类别通道**，只给类别 0 标注人脸，其余 79 类在训练损失中作为负类。不是把 `nc` 改为 1。
  因而保持当前 C 导出器、任务布局和板端 loader 的配置，先不要求修改 RTL/固件的类别形状。
- 训练中还包含 one2many 辅助头，部署时只导出 one2one。训练参数个数不能直接等于72层的整数权重个数。

GPU 不会让模型自动兼容硬件；结构、预处理、量化和部署包都要保留。
分支检查见 [板端模型审阅](../../docs/ziguang_face_model_review.md)。

## 当前状态与文件

2026-11-02 已完成本机 CPU 短自检：61,201 种均值舍入、窗口/RGB检查、WIDER边界数据、
浮点及 QAT 两次合成前向/反向、检查点往返、新权重首层的 NumPy/C 逐值对拍。
驱动已安装并重启，`nvidia-smi` 已识别 RTX 4050（6GB）；Conda 环境仍为 CPU 版 PyTorch。
**尚未下载完整数据、安装 GPU 版 PyTorch、执行正式人脸训练、运行新权重整网导出或验收精度。**

| 文件/模块 | 功能 |
| --- | --- |
| `check_gpu.py` | GPU/驱动及CUDA小张量反向检查 |
| `audit_board.py` | 只读审阅指定Git分支的模型契约/报告哈希 |
| `download_wider.py` | 显式下载、断点续传、SHA256、解压 |
| `prepare_wider.py` / `data.py` | WIDER标注、板端预处理、96缓存、批次拼接 |
| `model.py` / `assets.py` | 结构、部署权重解析及近似恢复初始化 |
| `train.py` / `evaluate.py` | 浮点→QAT训练、续训、AP50、最优检查点 |
| `predict.py` | 图片/目录的预处理、浮点/QAT检查点画框预览 |
| `export.py` | 完整整数导出、NumPy/C比对、板端SPI镜像 |
| `vendor/` | 最小参考训练/导出源、YAML、LUT、许可证、来源哈希 |

全部命令从工程根目录执行。依赖沿用已有 `yolo-fpga` Conda 环境，不创建项目虚拟环境。
运行结果在 `pc_ai/outputs/face/`，数据在 `pc_ai/datasets/`；两者均不提交 Git。
下列下载、全量缓存、训练和完整导出可能耗时较长，由用户执行。没有 `--run` 的准备命令不会自动开始长任务。

## 1. 本机 RTX 4050 驱动和训练环境

当前为 Ubuntu 22.04.5 / 内核 6.8.0-138，Secure Boot 已关闭。
2026-11-02 用户已安装驱动并重启，`nvidia-smi` 显示驱动 595.99.02、RTX 4050、6141MiB 显存。
Conda 环境仍为 torch 2.13.0+cpu / torchvision 0.28.0+cpu / ultralytics 8.4.115。

以下为 [Ubuntu 官方驱动安装方式](https://ubuntu.com/server/docs/how-to/graphics/install-nvidia-drivers/)，
本机已完成，留作新机器配置参考：

```bash
sudo apt update
sudo ubuntu-drivers install
# 安装完成、保存其它工作后，再重启：
sudo reboot
```

重启后先单独执行 `nvidia-smi`，确认能看到显卡；若失败，先解决驱动，不继续正式训练。
再替换同一个 Conda 环境里的 CPU PyTorch：

```bash
source ~/anaconda3/etc/profile.d/conda.sh
conda activate yolo-fpga
python -m pip install --upgrade -r pc_ai/requirements-gpu.txt
python -m pc_ai.face.check_gpu --require-cuda
```

GPU requirements 固定为 torch 2.13.0+cu130 / torchvision 0.28.0+cu130，未升级 Ultralytics。
已核对 [PyTorch 官方 cu130 轮子](https://download.pytorch.org/whl/cu130/torch/)，支持当前 Python 3.12 Linux。
[CUDA 13.x 驱动下限为 580](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html)，
当前已安装的595满足这个版本条件。该流程先使用预编译 PyTorch，不先安装额外的系统 CUDA Toolkit。
是否能真正训练以 CUDA 小张量检查和第一轮显存/吞吐为准，不凭显卡名称保证固定 batch 或训练时长。

## 2. 获取公开标注人脸数据

选用 [WIDER FACE](https://mmlab.ie.cuhk.edu.hk/projects/WIDERFace/index.html) 的训练和验证集。
下载源为 [CUHK-CSE 数据仓库](https://huggingface.co/datasets/CUHK-CSE/wider_face/tree/833d07e7bf3860f294242312fe95eed0561eeb17/data)，
固定公开提交及三份 ZIP 的原始 Git-LFS SHA256；训练/验证图像加标注约 1.83 GB，不下载测试图片。
原图、ZIP及96缓存都需磁盘空间，建议预留至少6GB。

```bash
python -m pc_ai.face.download_wider --run
```

如果官方 HF 网络不可用，可自行选择镜像并传 `--endpoint https://你的镜像域名`，同样强制校验 SHA256。
不需要平台账号密钥，也不把数据集/大模型写进源码目录。数据的原始来源/许可见官方数据卡。

也可手工下载解压，目录应为：

```text
pc_ai/datasets/wider_face/
  WIDER_train/images/...
  WIDER_val/images/...
  wider_face_split/wider_face_train_bbx_gt.txt
  wider_face_split/wider_face_val_bbx_gt.txt
```

## 3. 缓存与硬件一致的输入

```bash
python -m pc_ai.face.prepare_wider --root pc_ai/datasets/wider_face --run
```

每张图片先按双线性铺满 1920×1080，模拟进入板卡的一帧，再按板端窗口生成96×96 RGB：
水平20像素，垂直12像素，相邻垂直窗口按整数 floor/ceil 边界重叠；每窗口240像素平均，
最近舍入、半整数取偶。训练时再将0..255像素码除以255。
这匹配板端 `rgb888_pool96` / `rgb_mean240`，不是标准640 letterbox训练入口。
“铺满1080p”是数据构造选择；若实际送HDMI的程序在图像周围加黑边，验证图片也应包含这些黑边。
若HDMI有效行只有1919像素，板端补黑也会影响最右侧窗口，须用实际输入截图验收。

标签同步按归一化比例映射；有效小人脸不直接删除，缓存报告统计小于4个输入像素的脸。
无脸图片保留。96输入对密集/远距离小脸有先天信息限制，初期演示优先近景、少量人脸。

## 4. 正式训练

```bash
python -m pc_ai.face.check
python -m pc_ai.face.train --name face96 --epochs 60 --qat-start 40 --batch 16 --workers 2 --device cuda:0 --run
```

先40个epoch浮点适应，后20个epoch使用原参考W8A16 fake-quant/STE。未加入AMP，先保证量化稳定。
若显存不足，换新run并降低 `--batch`，例如8；训练耗时依据第一轮实际输出估计。
loss 使用框架的端到端双分支检测损失，全部标注类别为0；其余79类仍计算负样本损失。

没有原 `.pt`，默认用现有 `rearch_int8.bin` 近似恢复折叠权重，重新初始化分类末层，
将 one2one 初始化复制给训练辅助头。文件不保存原始 `s_w`，由部署乘数/尺度近似推回；
**这不是恢复原浮点训练检查点、原BN统计或优化器，也不能保证一定优于从头训练。**
可用 `--scratch` 显式从头训练做对照，或 `--weights-bin /路径/rearch_int8.bin` 指定资产。
使用自己的本入口检查点进行微调加 `--init 路径`；它不接受随意的官方YOLO检查点冒充同一结构。

每epoch在固定验证集评估，保存 `last.pt`、`best_float.pt` 和 `best_qat.pt`，日志 `epochs.jsonl`。
续训保持原来的 epochs、qat-start、batch、lr、seed及数据manifest：

```bash
python -m pc_ai.face.train --name face96 --resume pc_ai/outputs/face/runs/face96/last.pt --run
```

上例使用默认60/40/16配置；若首次修改过这些参数，续训时也须带相同参数。
GPU不可用时会报错，不静默改为长时间CPU训练。`--allow-cpu` 仅供明确需要时使用。
短联调可加 `--max-batches 1 --val-batches 1 --epochs 2 --qat-start 1`，此产物不能当正式训练成果。

验证指标是“经过96预处理的单类AP50”和阈值0.25下的precision/recall，**不是官方WIDER Easy/Medium/Hard AP**。
保留独立的真实HDMI场景照片用于最终验收；不能凭loss下降、训练完成或色块资产的旧结果宣称人脸精度合格。

## 5. 检查实拍画框

```bash
python -m pc_ai.face.predict --checkpoint pc_ai/outputs/face/runs/face96/best_qat.pt --image pc_ai/picture --limit 8
```

支持多种Pillow可解码图片格式。输出 `pc_ai/outputs/face/predictions/`，仅显示类别0。
这是QAT检查点的浮点执行参考；最终整数模型/板端的准确率还需另外检查。

## 6. 导出并回到已上板工程

预检不进行完整整数计算：

```bash
python -m pc_ai.face.export --checkpoint pc_ai/outputs/face/runs/face96/best_qat.pt
```

确定检查点后执行完整导出（可能较久）：

```bash
python -m pc_ai.face.export --checkpoint pc_ai/outputs/face/runs/face96/best_qat.pt --run
```

链路为：QAT范围/BN折叠 → Y26F W8A16 → 原C 99任务及原前向对拍 →
NumPy/C 的72卷积及10ADD逐值核对 → AIM1/AIP1 → `pc_ai/outputs/face/deploy/board_model.bin`。
使用诊断输入对拍只证明整数实现一致，不能替代人脸验证集准确率。
QAT浮点fake-quant与真实整数重定标仍有舍入和SPPF add量化差异，继承自参考方案；部署前须看整数实拍结果。

`deployment.json` 绑定检查点、数据集和镜像SHA，当前正式整网导出未运行。
保留原80通道布局后，预计仍为原99任务模型大小和板端内存配置；脚本实际检查低32MiB装载限制。
将最终 `board_model.bin` 交给Windows/RK已有SPI加载工具。不是把 `.pt`、Y26F二进制直接上传到模型装载地址。
板端模型运行前加载成功、原图/张量归属和结果frame_id仍按已有服务处理。

若需要对新参数再做整网RTL验证，在本工程运行（长仿真由用户启动）：

```bash
python pc_ai/prepare_trident_network.py --reference pc_ai/outputs/face/deploy/reference --out pc_ai/outputs/face/deploy/prepared --segment 0:99 --postprocess --simulator verilator --run
```

这是本工程main的仿真后端，不能自动代替Windows分支修改后RTL的整网验证。

## 云GPU使用

只要平台允许安装指定Python/PyTorch依赖、运行这些脚本并保存检查点，就可迁移；
[Colab提供GPU运行环境](https://research.google.com/colaboratory/faq.html)。不依赖本机FPGA、PDS或ModelSim进行训练。
上传 `pc_ai/face/` 及本地生成的 `wider96/` 缓存、整数初始化资产，保持同样的目录/模块入口；
用 `--data /云端路径/dataset.json --weights-bin /云端路径/rearch_int8.bin` 指定实际位置。
缓存中的原图路径只作来源记录，训练读取相对缓存路径，不要求云端有本地材料目录。
GPU环境应安装与平台驱动兼容的PyTorch，不能对驱动低于580的机器盲装cu130；Ultralytics仍锁定8.4.115。
训练完取回 `best_qat.pt`，本地使用完整工程完成C/RTL导出和上板。
