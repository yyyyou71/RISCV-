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
驱动已安装并重启，RTX 4050（6GB）与 torch 2.13.0+cu130 的CUDA前向/反向检查通过。
WIDER完整数据已校验、解压并缓存：训练12,880张、156,994个人脸框，验证3,226张、39,112个人脸框。
真实数据GPU短联调已完成：batch=16，浮点和QAT各训练1个批次、各验证1个批次，检查点保存成功；
约4.35秒，PyTorch峰值分配391MiB、保留458MiB。结果见`outputs/face/gpu_training_smoke.json`，
短检查点单独放在`outputs/face/runs/face96_gpu_smoke/`，只用于验证训练链路。
全量WIDER的`face96`正式训练已完整完成60轮（40轮浮点、20轮QAT）；近景子集已准备，`face96_close`微调尚未启动。
训练日志及完成标记已核对，两个最佳检查点加载、参数有限值及部署结构检查通过。
2026-11-02 对同一近景验证子集复测，结果见`outputs/face/review_face96/review.json`。
2026-11-04 人脸整数模型已导出至`outputs/face/deploy_spi/`，99任务C前向、82个卷积/ADD点的
NumPy/C逐值对拍通过；输入照片的C整数推理检出前景两张脸（约0.7610、0.3588）。
**新权重的RTL整网验证及人脸板端精度验收尚未完成。**

| 文件/模块 | 功能 |
| --- | --- |
| `check_gpu.py` | GPU/驱动及CUDA小张量反向检查 |
| `audit_board.py` | 只读审阅指定Git分支的模型契约/报告哈希 |
| `download_wider.py` | 显式下载、断点续传、SHA256、解压 |
| `prepare_wider.py` / `data.py` | WIDER标注、板端预处理、96缓存、批次拼接 |
| `filter_wider.py` | 按整图筛选近景、少量人脸，生成独立清单并复用缓存 |
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
Conda 环境已更换为 torch 2.13.0+cu130 / torchvision 0.28.0+cu130 / ultralytics 8.4.115，
`python -m pc_ai.face.check_gpu --require-cuda` 已通过。

以下为 [Ubuntu 官方驱动安装方式](https://ubuntu.com/server/docs/how-to/graphics/install-nvidia-drivers/)，
本机已完成，留作新机器配置参考：

```bash
sudo apt update
sudo ubuntu-drivers install
# 安装完成、保存其它工作后，再重启：
sudo reboot
```

新机器重启后先单独执行 `nvidia-smi`，确认能看到显卡；若失败，先解决驱动，不继续正式训练。
以下为同一个 Conda 环境替换 GPU PyTorch 的命令，本机也已完成，保留供新机器参考：

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

临时TLS断连、超时或部分服务器错误会自动重连，默认每个文件最多尝试5次，可用`--attempts`调整。
重跑会校验并复用已完成的ZIP与解压标记，未完成的`.part`尝试续传；收到数据时约每2秒更新进度。

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

### 3.1 当前演示目标：近景、少量人脸

用户已明确以对照图中第一、第三类较大人脸为目标。默认筛选规则为：
每张图片最多5个有效人脸框，每个框在96输入中的**宽和高都至少8像素**。
只要有一个有效框过小，就剔除整张图片；保留图片的全部有效标注不变，沿用原有invalid框处理规则。
原有空标注图片原样保留，不通过删除小脸标注生成新的空图。

```bash
python -m pc_ai.face.filter_wider --run
```

输出`pc_ai/outputs/face/wider96_close/dataset.json`。此操作只写新清单，使用相对路径引用原`wider96/`缓存，
不重复下载、复制或预处理图片；需要同时保留这两个目录。`--min-face-side`和`--max-faces`可调整规则。
本机默认筛选保留训练4,436张/5,908个人脸框、验证1,098张/1,485个人脸框，各含原有4张空标注图片。
预览见`pc_ai/outputs/face/dataset_preview/close_examples.png`，绿框为人工标注；宽高各放大3倍仅用于显示。
训练/验证划分保持不变，两组应用相同规则。新的AP50衡量该近景子集，不能直接与全量WIDER的AP50作提升对比；
比较模型改进时，应把旧、新检查点都放到同一验证子集评估。

全量训练得到的两个最佳检查点，已在同一近景验证子集（1,098张、1,485个人脸框）复测，作为后续微调的基线：

| 检查点 | 日志epoch | 近景AP50 | 精确率 | 召回率 |
| --- | --- | --- | --- | --- |
| `face96/best_float.pt` | 38 | 84.34% | 79.27% | 81.62% |
| `face96/best_qat.pt` | 56 | 83.88% | 79.07% | 81.68% |

精确率/召回率使用置信度0.25、IoU0.5；该近景评估沿用原验证划分，模型尚未在筛选后的训练子集上微调。
全量WIDER最佳QAT的AP50为18.53%，与上述子集的范围不同。QAT结果为PC端fake-quant推理，尚未运行完整整数导出或板端人脸验收。
预测预览在`pc_ai/outputs/face/review_face96/close_validation_predictions.png`，从近景验证集等间隔抽取8张；
绿框为人工标注，红框为预测；有手部误检、重复框，仍需改善并结合真实HDMI输入验收。

原`face96`已正常结束并保留结果。下一次可用已学过人脸的浮点检查点做近景微调：

```bash
python -m pc_ai.face.train --name face96_close \
  --data pc_ai/outputs/face/wider96_close/dataset.json \
  --init pc_ai/outputs/face/runs/face96/best_float.pt \
  --epochs 30 --qat-start 20 --lr 0.001 \
  --batch 16 --workers 2 --device cuda:0 --run
```

新run使用20轮浮点适应加10轮QAT；从`best_float.pt`初始化模型，优化器和训练轮数重新开始。
更换数据集用`--init`新建run，不能用`--resume`冒充原训练续跑。原`face96`结果完整保留。
若需中断后继续这一近景run，沿用相同配置：

```bash
python -m pc_ai.face.train --name face96_close \
  --data pc_ai/outputs/face/wider96_close/dataset.json \
  --resume pc_ai/outputs/face/runs/face96_close/last.pt \
  --epochs 30 --qat-start 20 --lr 0.001 \
  --batch 16 --workers 2 --device cuda:0 --run
```

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
python -m pc_ai.face.export --checkpoint pc_ai/outputs/face/runs/face96/best_qat.pt --out pc_ai/outputs/face/deploy_spi --run
```

链路为：QAT范围/BN折叠 → Y26F W8A16 → 原C 99任务及原前向对拍 →
NumPy/C 的72卷积及10ADD逐值核对 → AIM1/AIP1 → `pc_ai/outputs/face/deploy_spi/board_model.bin`。
同内容的人脸上传文件为`face_model.bin`，SHA256在`face_model.bin.sha256`，上板命令见该目录`DEPLOY.md`。
当前文件13,372,720字节，SHA256为`2d2e6d839a37cc31d745dfbb2e4d1cb4c3a0e1c619f12be496d048f62417bc87`。
使用诊断输入对拍只证明整数实现一致，不能替代人脸验证集准确率。
QAT浮点fake-quant与真实整数重定标仍有舍入和SPPF add量化差异，继承自参考方案；部署前须看整数实拍结果。

`deployment.json` 绑定检查点、数据集和镜像SHA，当前正式整网导出/C对拍已运行，结果覆盖847,908个中间值。
参考导出器还会提示三个整层权重大于512KiB的层；当前DDR分块引擎不要求整层片上驻留。
入口仅对与既有部署资产形状一致的这些层记录提示，仍检查其它算子、Q13/INT48范围、实际描述符和DDR布局。
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
