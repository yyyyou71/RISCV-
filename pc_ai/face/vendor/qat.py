#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
qat.py — REARCH-v1 S3 QAT int8（fake-quant + STE，实例级注入）
================================================================
量化语义对齐引擎既有口径（不发明新格式）：
- **权重 int8 per-out-channel 对称**：qmax=127、s=absmax_c/127、
  fq=clip(round(w/s),-127,127)·s —— 对齐 `yolo26_c/quant_lib.py` L34(QMAX)/
  L62-64(fq_tensor)/L66-76(quantize_weight_arr 'pc' 模式)。
- **权重=BN 折叠后**再量化（s=γ/√(var+1e-5)、W'=W·s、b'=β−mean·s）—— 对齐
  quant_lib.py L40-52(build_folded)/QUANT_EVAL.md §1.1；训练态用 batch 统计
  折叠（并同步维护 running 统计供导出），eval 态用 running 统计=部署口径。
- **激活 int16 对称、zero_point=0**、qmax=32767 —— 规格书 §5.3 S3 行
  「激活 int16 口径 fake-quant」；尺度=阈值/32767，对齐 quant_lib.py L21
  (A16 尺度换算)与 Accelerator_Architecture.md §4.2(RQ mult/shift 前 int32
  累加、bias 不量化=int32 初值)。
- **尺度=EMA 固定阈值**（train 时 momentum=0.1 滑动更新，eval 冻结）—— 对齐
  quant_lib.py L11-12「尺度固定，不按图自适应」（FPGA 编译期常量）。
- 注入点：每个 Conv(conv+BN+ReLU)输出、检测头裸 Conv2d 输出、Bottleneck
  残差 add 输出 —— 对齐 QUANT_EVAL.md §1.1「conv_bn 输出/shortcut add/
  检测头末层 logits」量化钩子点。sigmoid/exp 走 LUT 不做线性量化（同上 §1.1）。

**实例级注入**（只改学生，teacher 共享 nn 类不受影响）：
遍历学生 model.modules()，对 Conv / 裸 Conv2d / Bottleneck 实例替换 forward
（实例属性遮蔽类方法），观察器阈值注册为 buffer（随 state_dict 保存→续训连续）。
不 import 本模块即为 fp32 原始环境 = 回滚路径。
"""
from __future__ import annotations
import torch
import torch.nn as nn
import torch.nn.functional as F

QMAX_W = 127        # int8 对称（quant_lib.py L34）
QMAX_A = 32767      # int16 对称（同上）
ACT_MOMENTUM = 0.1  # 激活阈值 EMA
_EPS = 1e-12


def _ste(x: torch.Tensor, xq: torch.Tensor) -> torch.Tensor:
    """Straight-Through Estimator：前向取量化值，反向上游梯度直通。"""
    return x + (xq - x).detach()


def fq_weight_pc(w: torch.Tensor) -> torch.Tensor:
    """权重 fake-quant：per-out-channel 对称 int8（quant_lib.py L66-76 逐行对应）。"""
    amax = w.detach().abs().flatten(1).amax(1).clamp_min(_EPS)
    s = (amax / QMAX_W).view(-1, 1, 1, 1)
    wq = torch.clamp(torch.round(w / s), -QMAX_W, QMAX_W) * s
    return _ste(w, wq), amax / QMAX_W


def _act_fq(mod: nn.Module, y: torch.Tensor) -> torch.Tensor:
    """激活 fake-quant：int16 对称 + EMA 固定阈值（buffer `_fq_thr`）。"""
    thr_buf = mod._fq_thr
    if mod.training:
        with torch.no_grad():
            cur = y.detach().abs().max()
            if torch.isnan(thr_buf).any():
                thr_buf.fill_(float(cur))
            else:
                thr_buf.mul_(1 - ACT_MOMENTUM).add_(ACT_MOMENTUM * cur)
    thr = thr_buf.clamp_min(_EPS)
    s = thr / QMAX_A
    yq = torch.clamp(torch.round(y / s), -QMAX_A, QMAX_A) * s
    return _ste(y, yq)


def _dev_of(m):
    p = next(m.parameters(), None)
    return p.device if p is not None else torch.device("cpu")


def _install_conv_qat(m: nn.Module):
    """Conv(conv+BN+act) 实例 → BN 折叠 + 权重 int8 fq + 激活 int16 fq。"""
    m.register_buffer("_fq_thr", torch.tensor(float("nan"), device=_dev_of(m)))
    conv, bn = m.conv, m.bn

    def qat_forward(self, x):
        if self.training:
            pre = F.conv2d(x, conv.weight, None, conv.stride, conv.padding,
                           conv.dilation, conv.groups)
            var_b, mean_b = torch.var_mean(pre, dim=(0, 2, 3), unbiased=False)
            with torch.no_grad():  # 与 BN 同规则维护 running 统计（供导出折叠）
                mom = bn.momentum
                bn.running_mean.mul_(1 - mom).add_(mom * mean_b)
                var_u = torch.var(pre, dim=(0, 2, 3), unbiased=True)
                bn.running_var.mul_(1 - mom).add_(mom * var_u)
                bn.num_batches_tracked.add_(1)
            mean, var = mean_b, var_b
        else:
            mean, var = bn.running_mean, bn.running_var
        s = bn.weight / torch.sqrt(var + bn.eps)          # quant_lib.py L49
        w_fold = conv.weight * s.view(-1, 1, 1, 1)        # L50
        b_fold = bn.bias - mean * s                       # L51
        wq, _ = fq_weight_pc(w_fold)
        out = F.conv2d(x, wq, b_fold, conv.stride, conv.padding,
                       conv.dilation, conv.groups)
        out = self.act(out)
        return _act_fq(self, out)

    m.forward = qat_forward.__get__(m, type(m))


def _install_plain_conv2d_qat(m: nn.Conv2d):
    """检测头末层裸 Conv2d（无 BN）→ 权重直接 fq + 输出 fq（QUANT_EVAL §1.1）。"""
    m.register_buffer("_fq_thr", torch.tensor(float("nan"), device=_dev_of(m)))

    def qat_forward(self, x):
        wq, _ = fq_weight_pc(self.weight)
        out = F.conv2d(x, wq, self.bias, self.stride, self.padding,
                       self.dilation, self.groups)
        return _act_fq(self, out)

    m.forward = qat_forward.__get__(m, type(m))


def _install_bottleneck_qat(m):
    """Bottleneck 残差 add 输出 fq（cv1/cv2 已按 Conv 注入）。"""
    m.register_buffer("_fq_thr", torch.tensor(float("nan"), device=_dev_of(m)))

    def qat_forward(self, x):
        y = self.cv2(self.cv1(x))
        if self.add:
            return _act_fq(self, x + y)
        return y

    m.forward = qat_forward.__get__(m, type(m))


def apply_qat(model: nn.Module, verbose: bool = True) -> dict:
    """对学生模型实例级注入 QAT。返回统计 {conv, plain_conv2d, bottleneck}。"""
    from ultralytics.nn.modules.conv import Conv
    from ultralytics.nn.modules.block import Bottleneck
    inner = {id(m.conv) for m in model.modules() if isinstance(m, Conv)}  # Conv 内层不重复注入
    stats = {"conv": 0, "plain_conv2d": 0, "bottleneck": 0}
    for m in model.modules():
        if isinstance(m, Conv):
            _install_conv_qat(m)
            stats["conv"] += 1
        elif type(m) is nn.Conv2d and id(m) not in inner:  # 裸 Conv2d（检测头末层）
            _install_plain_conv2d_qat(m)
            stats["plain_conv2d"] += 1
        elif isinstance(m, Bottleneck):
            _install_bottleneck_qat(m)
            stats["bottleneck"] += 1
    if verbose:
        print(f"[qat] 注入完成: Conv×{stats['conv']} 裸Conv2d×{stats['plain_conv2d']} "
              f"Bottleneck×{stats['bottleneck']}（W int8 pc 对称 / A int16 对称, qmax 127/32767）")
    return stats
