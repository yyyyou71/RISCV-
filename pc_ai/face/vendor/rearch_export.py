#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rearch_export.py — REARCH-v1 int8 定点导出（从 QAT checkpoint）
================================================================
复刻 yolo26_c/export_fixed.py 的整数数据通路语义（本脚本即 REARCH 定点可执行规范），
差异点：
  1. 权重/激活尺度直接来自 QAT checkpoint：BN running 统计折叠 → int8 per-channel；
     激活全 int16，尺度 = `_fq_thr` buffer / 32767（规格书 §5.3 口径，不做二次标定）。
  2. SiLU LUT → ReLU：Q6.13 中间域 clamp ≥ 0，精确无 LUT（引擎侧 LUT 重烧/旁路是
     RTL 资产事项，见报告兼容点）。
  3. 架构 = REARCH-v1：C3FPGA×9（cv1/cv2 1×1 + Bottleneck 双 3×3 + ADD + cv3 1×1）、
     SPPF n=1（cv1 act=False → 1×pool5 → 2 路 cat → cv2 → 残差 ADD）、检测头
     one2one 分支全普通卷积（box 3×3+3×3+1×1，cls 3×3+3×3+1×1）。无 attn / dw。
  4. SPPF 残差 add 在 QAT 中未注入 `_fq_thr`（SPPF 非 Bottleneck）→ 导出策略
     thr_add = thr(x8) + thr(model.9.cv2)（两操作数阈值和，保不饱和；语义差见报告）。

产出（--out 目录下，默认 training/export）：
  rearch_int8.bin            Y26F v1 格式（convs/points/adds/attns=0/sigs 五段，parser 零改）
  golden_int/tb96/*.npy      int16 黄金张量（含 input）+ meta.json
  tb_vectors/input.hex       tb96 合成输入（(x+y+c*37)%256，CHW，每行 2 位 hex）
  tb_vectors/manifest.json
  scales.json                每点尺度与来源
  export_report.json         卷积清单 / MACs / ISA 校验 / 溢出统计

用法：python training/export/rearch_export.py --ckpt training/runs/s3_qat/last.pt
"""
from __future__ import annotations
import argparse
import json
import math
import os
import struct
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent           # training/export/
ROOT = HERE                                # training/
PROJ = HERE                                # TridentVision_auto_work/
sys.path.insert(0, str(ROOT))

QMAX_W = 127
QMAX_A = 32767
MAXM = (1 << 27) - 1                              # mult 上限（acc≤2^35 时 int64 不溢出）
RHU = True                                        # round-half-up（对齐 V1.0 默认）

# ---------------------------------------------------------------- LUT（sigmoid 沿用 V1.0 标定 .mem，与 RTL 同源）
def _load_mem(name, bits, signed):
    vals = [int(l.strip(), 16) for l in open(HERE / name, encoding="ascii") if l.strip()]
    a = np.array(vals, dtype=np.int64)
    if signed:
        a = np.where(a >= (1 << (bits - 1)), a - (1 << bits), a)
    return a

SIG_Y = _load_mem("lut_sigmoid_y.mem", 16, False)   # 32 段, 域[-8,8], Q0.16 u16
SIG_DY = _load_mem("lut_sigmoid_dy.mem", 16, True)

# ---------------------------------------------------------------- 整数原语（与 export_fixed.py 逐行同语义）
def shr(a, sh):
    """全局右移：RHU 时加 1<<(sh-1) 再移；否则算术右移 floor。int64。"""
    a = np.asarray(a, np.int64)
    if sh <= 0:
        return a << (-sh)
    if RHU:
        return (a + (1 << (sh - 1))) >> sh
    return a >> sh

def synth(r):
    """标量比率 r>0 → (mult, shift)：mult=round(r*2^shift) ≤ MAXM，shift 取最大非负。"""
    sh = max(0, int(math.floor(math.log2(MAXM / r))))
    m = int(round(r * (1 << sh)))
    while m > MAXM:
        sh -= 1
        m = int(round(r * (1 << sh)))
    return m, sh

def synth_vec(r):
    """逐通道比率 (O,) → 共享 shift 的 (mult[O], shift)。"""
    r = np.asarray(r, np.float64)
    sh = max(0, int(math.floor(math.log2(MAXM / r.max()))))
    m = np.round(r * (1 << sh)).astype(np.int64)
    while m.max() > MAXM:
        sh -= 1
        m = np.round(r * (1 << sh)).astype(np.int64)
    return m, sh

def sigmoid_off(x412):
    """sigmoid LUT：输入 Q4.12 → OFF=x+32768 钳 [0,65535] → Q0.16。"""
    off = np.clip(np.asarray(x412, np.int64) + 32768, 0, 65535)
    idx = off >> 11
    frac = off & 2047
    return SIG_Y[idx] + ((frac * SIG_DY[idx]) >> 11)

# ---------------------------------------------------------------- 注册表
CONVS, ADDS, SIGS = [], [], []
POINTS = {}          # name -> (bits, scale)
DUMPS = {}           # name -> int16 (C,H,W)
OVERFLOW = {}        # name -> max|acc|
Y13_CLAMP = {}       # name -> |y13|≥2^31 计数（应为 0）
SCALE = {}           # name -> float 激活尺度（thr/32767）
SCALE_SRC = {}       # name -> 尺度来源说明

def scale_of(p):
    return SCALE[p]

def _dump(p, arr):
    DUMPS[p] = arr.astype(np.int16)

# ---------------------------------------------------------------- 卷积引擎（int64 累加 → Q6.13 → ReLU → 反量化 int16）
def conv2d_acc(xq, wq, stride, pad):
    """xq (C,H,W) int、wq (O,C,kh,kw) int8 → acc (O,Ho,Wo) int64（模拟 DSP48 int48 域）。"""
    C, H, Wd = xq.shape
    O, _, kh, kw = wq.shape
    xp = np.pad(xq.astype(np.int64), ((0, 0), (pad, pad), (pad, pad))) if pad else xq.astype(np.int64)
    Ho = (H + 2 * pad - kh) // stride + 1
    Wo = (Wd + 2 * pad - kw) // stride + 1
    acc = np.zeros((O, Ho, Wo), np.int64)
    for ky in range(kh):
        for kx in range(kw):
            patch = xp[:, ky:ky + stride * (Ho - 1) + 1:stride, kx:kx + stride * (Wo - 1) + 1:stride]
            acc += np.einsum("oc,chw->ohw", wq[:, :, ky, kx].astype(np.int64), patch)
    return acc

def conv_layer(xq, groups, wname, act=True, k=3, s=1, plain=False):
    """整数卷积层：分组累加 → Q6.13 中间域（+bias_q13）→ ReLU → 反量化到 int16。
    groups: [(ch0, ch1, sx), ...] 输入通道分组（concat 多尺度，各组独立 multM/shiftM 后相加）。
    plain=True 用裸 Conv2d 权重（检测头末层，无 BN 无激活）。"""
    point = wname
    wq8, ws, b = WQ[wname]
    pad = 0 if plain else k // 2
    y13 = None
    greg = []
    for (c0, c1, sx) in groups:
        acc = conv2d_acc(xq[c0:c1], wq8[:, c0:c1], s, pad)
        OVERFLOW[point] = max(OVERFLOW.get(point, 0), int(np.abs(acc).max()))
        multM, shiftM = synth_vec(ws * sx * 8192.0)     # multM = s_w[o]*s_x*2^13
        yg = shr(acc * multM[:, None, None], shiftM)
        y13 = yg if y13 is None else y13 + yg
        greg.append({"ch0": c0, "ch1": c1, "sx": sx, "shiftM": int(shiftM),
                     "multM": multM.tolist()})
    # ---- bias 在 Q13 域加（不进累加器，解耦多尺度组）
    y13 = y13 + np.round(b * 8192.0).astype(np.int64)[:, None, None]
    n_clamp = int((np.abs(y13) >= (1 << 31)).sum())
    if n_clamp:
        Y13_CLAMP[point] = Y13_CLAMP.get(point, 0) + n_clamp
    y13 = np.clip(y13, -(1 << 31), (1 << 31) - 1)
    # ---- ReLU（Q6.13 域 clamp≥0，精确无 LUT）
    if act:
        y13 = np.maximum(y13, 0)
    # ---- 反量化到 int16
    so = scale_of(point)
    multY, shiftY = synth(1.0 / (8192.0 * so))
    out = np.clip(shr(y13 * multY, shiftY), -QMAX_A, QMAX_A).astype(np.int16)
    O = wq8.shape[0]
    CONVS.append({"name": point, "kind": ("plain" if plain else "conv"),
                  "act": int(act), "O": int(O), "C": int(xq.shape[0]), "k": k, "s": s,
                  "pad": pad, "groups": greg, "bias_q13": np.round(b * 8192.0).astype(np.int64).tolist(),
                  "multY": multY, "shiftY": shiftY, "out_bits": 16, "out_scale": so,
                  "H": int(xq.shape[1]), "W": int(xq.shape[2]), "w": wq8})
    POINTS[point] = (16, so)
    _dump(point, out)
    return out

def add_point(aq, sa, bq, sb, point):
    """add 点：out_q = (a_q*multA>>shA) + (b_q*multB>>shB)，mult 为尺度比。"""
    so = scale_of(point)
    multA, shA = synth(sa / so)
    multB, shB = synth(sb / so)
    out = np.clip(shr(aq.astype(np.int64) * multA, shA) + shr(bq.astype(np.int64) * multB, shB),
                  -QMAX_A, QMAX_A).astype(np.int16)
    ADDS.append({"name": point, "bits": 16, "scale": so,
                 "multA": multA, "shiftA": shA, "multB": multB, "shiftB": shB})
    POINTS[point] = (16, so)
    _dump(point, out)
    return out

def maxpool5(y):
    """5x5 maxpool s1 p2，常量 -32768 填充（对齐 PyTorch -inf）。"""
    C, H, Wd = y.shape
    xp = np.pad(y.astype(np.int32), ((0, 0), (2, 2), (2, 2)), mode="constant", constant_values=-32768)
    out = np.full((C, H, Wd), -32768, np.int32)
    for ky in range(5):
        for kx in range(5):
            np.maximum(out, xp[:, ky:ky + H, kx:kx + Wd], out=out)
    return out.astype(np.int16)

def upsample2x(y):
    return np.repeat(np.repeat(y, 2, axis=1), 2, axis=2)

# ---------------------------------------------------------------- 模块级整数前向（REARCH 结构）
def bottleneck_int(x, sx, p):
    """C3FPGA Bottleneck：cv1 3×3 → cv2 3×3 → 残差 ADD（shortcut=True）。"""
    y = conv_layer(x, [(0, x.shape[0], sx)], p + ".cv1", k=3)
    y = conv_layer(y, [(0, y.shape[0], scale_of(p + ".cv1"))], p + ".cv2", k=3)
    return add_point(x, sx, y, scale_of(p + ".cv2"), p + ".add")

def c3fpga_int(x, groups, li):
    """C3FPGA：cv1 1×1 → m.0 Bottleneck；cv2 1×1 旁路；cat[m,cv2] → cv3 1×1。
    x 为整输入张量；groups 为 x 的分组尺度（跨层 concat 时 2 组，否则 1 组）。"""
    p = f"model.{li}"
    a = conv_layer(x, groups, p + ".cv1", k=1)
    z = bottleneck_int(a, scale_of(p + ".cv1"), p + ".m.0")
    b = conv_layer(x, groups, p + ".cv2", k=1)
    cat = np.concatenate([z, b], axis=0)
    ca = z.shape[0]
    return conv_layer(cat, [(0, ca, scale_of(p + ".m.0.add")),
                            (ca, cat.shape[0], scale_of(p + ".cv2"))], p + ".cv3", k=1)

def sppf_int(x, sx):
    """SPPF n=1 + shortcut：cv1 1×1(act=False) → 1×pool5 → cat[y0,y1] → cv2 1×1 → 残差 ADD。"""
    p = "model.9"
    y0 = conv_layer(x, [(0, x.shape[0], sx)], p + ".cv1", act=False, k=1)
    s0 = scale_of(p + ".cv1")
    y1 = maxpool5(y0)                                    # pool 保尺度 → 单组
    cat = np.concatenate([y0, y1], axis=0)
    y = conv_layer(cat, [(0, cat.shape[0], s0)], p + ".cv2", act=True, k=1)
    return add_point(x, sx, y, scale_of(p + ".cv2"), p + ".add")

# ---------------------------------------------------------------- 检测头 + 整数后处理（沿用 V1.0 口径）
def make_anchors_rect(feat_hw, strides=(8, 16, 32)):
    anchors, sv = [], []
    for (h, w), st in zip(feat_hw, strides):
        gy, gx = np.meshgrid(np.arange(h) + 0.5, np.arange(w) + 0.5, indexing="ij")
        anchors.append(np.stack([gx, gy], -1).reshape(-1, 2))
        sv.append(np.full((h * w,), st, dtype=np.float64))
    return np.concatenate(anchors), np.concatenate(sv)

def detect_int(feats, H, W):
    """feats: [x16, x19, x22]（int16）。返回 boxes_xyxy(float)、z 整数 Q0.16 (M,80)。"""
    boxes_f, z_int = [], []
    for i, f in enumerate(feats):
        sf = scale_of(f"model.{16 + 3 * i}.cv3")
        bp = f"model.23.one2one_cv2.{i}"
        y = conv_layer(f, [(0, f.shape[0], sf)], bp + ".0", k=3)
        y = conv_layer(y, [(0, y.shape[0], scale_of(bp + ".0"))], bp + ".1", k=3)
        y = conv_layer(y, [(0, y.shape[0], scale_of(bp + ".1"))], bp + ".2",
                       act=False, k=1, plain=True)          # (4,h,w) int16
        s_box = scale_of(bp + ".2")
        boxes_f.append((y.astype(np.float64) * s_box).reshape(4, -1))
        cp = f"model.23.one2one_cv3.{i}"
        z = conv_layer(f, [(0, f.shape[0], sf)], cp + ".0", k=3)
        z = conv_layer(z, [(0, z.shape[0], scale_of(cp + ".0"))], cp + ".1", k=3)
        z = conv_layer(z, [(0, z.shape[0], scale_of(cp + ".1"))], cp + ".2",
                       act=False, k=1, plain=True)          # (80,h,w) int16
        s_cls = scale_of(cp + ".2")
        multL, shL = synth(s_cls * 4096.0)                   # logit → Q4.12
        X = shr(z.astype(np.int64) * multL, shL)
        zi = sigmoid_off(X).reshape(80, -1)                  # Q0.16
        z_int.append(zi)
        SIGS.append({"head": i, "box_point": bp + ".2", "cls_point": cp + ".2",
                     "multL": multL, "shiftL": shL, "s_box": s_box, "s_cls": s_cls})
    boxes = np.concatenate(boxes_f, axis=1)                  # (4,M) l,t,r,b
    zcat = np.concatenate(z_int, axis=1)                     # (80,M)
    anchors, strides = make_anchors_rect([(H // 8, W // 8), (H // 16, W // 16), (H // 32, W // 32)])
    l, t, r, b = boxes[0], boxes[1], boxes[2], boxes[3]
    ax, ay = anchors[:, 0], anchors[:, 1]
    x1 = (ax - l) * strides; y1 = (ay - t) * strides
    x2 = (ax + r) * strides; y2 = (ay + b) * strides
    return np.stack([x1, y1, x2, y2], axis=1), zcat.T        # (M,4), (M,80) Q0.16

def postprocess_int(boxes_xyxy, zmat, max_det=300):
    """top-k 纯整数比较（Q0.16 单调保序，stable 排序保证与 C 一致）。"""
    na, nc = zmat.shape
    k = min(max_det, na)
    amax = zmat.max(axis=1)
    sel = np.argsort(-amax, kind="stable")[:k]
    sub = zmat[sel].reshape(-1)
    k2 = min(max_det, sub.size)
    flat = np.argsort(-sub, kind="stable")[:k2]
    aidx = sel[flat // nc]
    cidx = flat % nc
    score = sub[flat].astype(np.float64) / 65536.0
    out = np.concatenate([boxes_xyxy[aidx], score[:, None],
                          cidx[:, None].astype(np.float64)], axis=1)
    return out                                               # (k2,6)

# ---------------------------------------------------------------- 完整前向（REARCH-v1 序列，镜像 yaml）
def forward_int(xq, H, W):
    """xq: (3,H,W) int16（uint8 像素值，尺度 1/255 精确）。返回 (dets, boxes, zmat)。"""
    DUMPS.clear()
    _dump("input", xq)
    POINTS["input"] = (16, 1.0 / 255.0)
    y = conv_layer(xq, [(0, 3, 1.0 / 255.0)], "model.0", k=3, s=2)
    y = conv_layer(y, [(0, y.shape[0], scale_of("model.0"))], "model.1", k=3, s=2)
    x = c3fpga_int(y, [(0, y.shape[0], scale_of("model.1"))], 2)
    y = conv_layer(x, [(0, x.shape[0], scale_of("model.2.cv3"))], "model.3", k=3, s=2)
    x4 = c3fpga_int(y, [(0, y.shape[0], scale_of("model.3"))], 4)
    y = conv_layer(x4, [(0, x4.shape[0], scale_of("model.4.cv3"))], "model.5", k=3, s=2)
    x6 = c3fpga_int(y, [(0, y.shape[0], scale_of("model.5"))], 6)
    y = conv_layer(x6, [(0, x6.shape[0], scale_of("model.6.cv3"))], "model.7", k=3, s=2)
    x8 = c3fpga_int(y, [(0, y.shape[0], scale_of("model.7"))], 8)
    x9 = sppf_int(x8, scale_of("model.8.cv3"))
    x10 = c3fpga_int(x9, [(0, x9.shape[0], scale_of("model.9.add"))], 10)
    i13 = np.concatenate([upsample2x(x10), x6], axis=0)
    x13 = c3fpga_int(i13, [(0, x10.shape[0], scale_of("model.10.cv3")),
                           (x10.shape[0], i13.shape[0], scale_of("model.6.cv3"))], 13)
    i16 = np.concatenate([upsample2x(x13), x4], axis=0)
    x16 = c3fpga_int(i16, [(0, x13.shape[0], scale_of("model.13.cv3")),
                           (x13.shape[0], i16.shape[0], scale_of("model.4.cv3"))], 16)
    x17 = conv_layer(x16, [(0, x16.shape[0], scale_of("model.16.cv3"))], "model.17", k=3, s=2)
    i19 = np.concatenate([x17, x13], axis=0)
    x19 = c3fpga_int(i19, [(0, x17.shape[0], scale_of("model.17")),
                           (x17.shape[0], i19.shape[0], scale_of("model.13.cv3"))], 19)
    x20 = conv_layer(x19, [(0, x19.shape[0], scale_of("model.19.cv3"))], "model.20", k=3, s=2)
    i22 = np.concatenate([x20, x10], axis=0)
    x22 = c3fpga_int(i22, [(0, x20.shape[0], scale_of("model.20")),
                           (x20.shape[0], i22.shape[0], scale_of("model.10.cv3"))], 22)
    boxes, zmat = detect_int([x16, x19, x22], H, W)
    return postprocess_int(boxes, zmat), boxes, zmat

# ---------------------------------------------------------------- 模型加载与权重/尺度提取
C3_LAYERS = [2, 4, 6, 8, 10, 13, 16, 19, 22]

def expected_conv_names():
    """全部 72 个卷积点名（推理路径，one2one 头），拓扑序与前向一致，便于报告逐行对账。"""
    order = ["model.0", "model.1",
             "model.2.cv1", "model.2.m.0.cv1", "model.2.m.0.cv2", "model.2.cv2", "model.2.cv3",
             "model.3",
             "model.4.cv1", "model.4.m.0.cv1", "model.4.m.0.cv2", "model.4.cv2", "model.4.cv3",
             "model.5",
             "model.6.cv1", "model.6.m.0.cv1", "model.6.m.0.cv2", "model.6.cv2", "model.6.cv3",
             "model.7",
             "model.8.cv1", "model.8.m.0.cv1", "model.8.m.0.cv2", "model.8.cv2", "model.8.cv3",
             "model.9.cv1", "model.9.cv2",
             "model.10.cv1", "model.10.m.0.cv1", "model.10.m.0.cv2", "model.10.cv2", "model.10.cv3",
             "model.13.cv1", "model.13.m.0.cv1", "model.13.m.0.cv2", "model.13.cv2", "model.13.cv3",
             "model.16.cv1", "model.16.m.0.cv1", "model.16.m.0.cv2", "model.16.cv2", "model.16.cv3",
             "model.17",
             "model.19.cv1", "model.19.m.0.cv1", "model.19.m.0.cv2", "model.19.cv2", "model.19.cv3",
             "model.20",
             "model.22.cv1", "model.22.m.0.cv1", "model.22.m.0.cv2", "model.22.cv2", "model.22.cv3"]
    for i in range(3):
        bp = f"model.23.one2one_cv2.{i}"
        cp = f"model.23.one2one_cv3.{i}"
        order += [bp + ".0", bp + ".1", bp + ".2", cp + ".0", cp + ".1", cp + ".2"]
    assert len(order) == 72 and len(set(order)) == 72, "卷积清单不自洽（应 72 个且不重复）"
    return order

WQ = {}          # name -> (w_int8 (O,C,kh,kw), ws (O,) float64, bias float64 (O,))

def _thr(mod, name):
    import torch
    t = float(mod._fq_thr)
    if math.isnan(t):
        raise SystemExit(f"[export] {name} 的 _fq_thr 为 NaN——该模块未经历 QAT 训练前向")
    return t

def load_model(ckpt_path):
    import torch
    from . import patches
    patches.apply_all(verbose=False)
    from ultralytics.nn.tasks import DetectionModel
    model = DetectionModel(str(PROJ / "yolo26m_fpga.yaml"), ch=3, nc=80, verbose=False)
    ck = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
    if any("_fq_thr" in k for k in ck["model"]):
        from . import qat
        qat.apply_qat(model, verbose=False)
    else:
        raise SystemExit("[export] checkpoint 无 _fq_thr buffer——不是 QAT ckpt")
    model.load_state_dict(ck["model"])
    model.eval()
    return model, ck

def build_wq_and_scales(model):
    """BN running 折叠 → int8 pc 权重 + fp64 bias；激活尺度来自 _fq_thr。"""
    import torch
    from ultralytics.nn.modules.conv import Conv
    mods = dict(model.named_modules())
    names = expected_conv_names()
    for nm in names:
        if nm not in mods:
            raise SystemExit(f"[export] 模块缺失: {nm}（架构与 REARCH-v1 不符）")
    # 结构断言（SPPF n=1 + shortcut；Detect reg_max=1）
    sppf = mods["model.9"]
    assert getattr(sppf, "n", None) == 1 and getattr(sppf, "add", None) is True, "SPPF 非 n=1+shortcut"
    det = mods["model.23"]
    assert det.reg_max == 1 and det.end2end, "Detect 非 reg_max=1 end2end"
    for nm in names:
        m = mods[nm]
        plain = type(m) is torch.nn.Conv2d
        if plain:
            w = m.weight.detach().double().numpy()
            b = m.bias.detach().double().numpy()
        else:
            assert isinstance(m, Conv), f"{nm} 类型异常: {type(m)}"
            conv, bn = m.conv, m.bn
            s = bn.weight / torch.sqrt(bn.running_var + bn.eps)   # running 统计（eval=部署口径）
            w = (conv.weight * s.view(-1, 1, 1, 1)).detach().double().numpy()
            b = (bn.bias - bn.running_mean * s).detach().double().numpy()
        ws = np.maximum(np.abs(w).reshape(w.shape[0], -1).max(1), 1e-12) / QMAX_W
        w_int = np.clip(np.round(w / ws[:, None, None, None]), -QMAX_W, QMAX_W).astype(np.int8)
        WQ[nm] = (w_int, ws.astype(np.float64), b)
        SCALE[nm] = _thr(m, nm) / QMAX_A
        SCALE_SRC[nm] = f"qat _fq_thr ({nm})"
    # Bottleneck 残差 add 点
    from ultralytics.nn.modules.block import Bottleneck
    for li in C3_LAYERS:
        bn_mod = mods[f"model.{li}.m.0"]
        assert isinstance(bn_mod, Bottleneck) and bn_mod.add, f"model.{li}.m.0 非 shortcut Bottleneck"
        p = f"model.{li}.m.0.add"
        SCALE[p] = _thr(bn_mod, p) / QMAX_A
        SCALE_SRC[p] = f"qat _fq_thr (model.{li}.m.0)"
    # SPPF 残差 add（QAT 未注入 → 阈值和策略，保不饱和）
    thr_x = float(mods["model.8.cv3"]._fq_thr)
    thr_y = float(mods["model.9.cv2"]._fq_thr)
    SCALE["model.9.add"] = (thr_x + thr_y) / QMAX_A
    SCALE_SRC["model.9.add"] = ("thr(model.8.cv3)+thr(model.9.cv2)——SPPF add 无 _fq_thr "
                                "（QAT 未注入点），取操作数阈值和保不饱和")
    SCALE["input"] = 1.0 / 255.0
    SCALE_SRC["input"] = "uint8 像素 /255（前端精确）"
    print(f"[export] 权重 {len(WQ)} 卷积；尺度点 {len(SCALE)}（含 10 add + input）")

# ---------------------------------------------------------------- yolo26m_int8.bin（Y26F v1，parser 零改）
def _name48(s):
    b = s.encode("ascii")
    assert len(b) < 48
    return b + b"\0" * (48 - len(b))

def write_bin(path):
    kind_id = {"conv": 0, "plain": 2}
    with open(path, "wb") as f:
        f.write(struct.pack("<4s7I", b"Y26F", 1, len(CONVS), len(POINTS), len(ADDS), 0, len(SIGS), 0))
        for c in CONVS:
            wq8 = c["w"]
            O, C, kh, kw = wq8.shape
            f.write(_name48(c["name"]))
            f.write(struct.pack("<4B", kind_id[c["kind"]], c["act"], len(c["groups"]), c["out_bits"]))
            f.write(struct.pack("<7I", O, C, kh, kw, c["s"], c["s"], c["pad"]))
            f.write(struct.pack("<f2i", c["out_scale"], c["multY"], c["shiftY"]))
            for g in c["groups"]:
                f.write(struct.pack("<2Iif", g["ch0"], g["ch1"], g["shiftM"], g["sx"]))
            for g in c["groups"]:
                f.write(np.asarray(g["multM"], np.int32).tobytes())
            f.write(np.asarray(c["bias_q13"], np.int32).tobytes())
            f.write(wq8.tobytes())
        for name, (bits, scale) in POINTS.items():
            f.write(_name48(name))
            f.write(struct.pack("<B3xf", bits, scale))
        for a in ADDS:
            f.write(_name48(a["name"]))
            f.write(struct.pack("<B3xf4i", a["bits"], a["scale"],
                                a["multA"], a["shiftA"], a["multB"], a["shiftB"]))
        for g in SIGS:
            f.write(struct.pack("<I", g["head"]))
            f.write(_name48(g["box_point"]))
            f.write(_name48(g["cls_point"]))
            f.write(struct.pack("<2i2f", g["multL"], g["shiftL"], g["s_box"], g["s_cls"]))

# ---------------------------------------------------------------- ISA / MAC 统计
def conv_stats():
    """逐 conv 的 MACs / padded MACs / beats / 权重复字节 / ISA 标志。"""
    rows = []
    for c in CONVS:
        O, C, k, s = c["O"], c["C"], c["k"], c["s"]
        Ho = (c["H"] + 2 * c["pad"] - k) // s + 1
        Wo = (c["W"] + 2 * c["pad"] - k) // s + 1
        macs = O * C * k * k * Ho * Wo
        it, ot = (C + 15) // 16, (O + 15) // 16
        padded = it * 16 * ot * 16 * k * k * Ho * Wo
        w_bytes = O * C * k * k
        isa = {
            "k_in_{1,3}": k in (1, 3),
            "s_in_{1,2}": s in (1, 2),
            "cin_16x": (C % 16 == 0) or c["name"] == "model.0",
            "cout_16x": (O % 16 == 0) or O in (4, 80),
            "groups_le2": len(c["groups"]) <= 2,
            "w_le_512KB": w_bytes <= 512 * 1024,
        }
        rows.append({"name": c["name"], "C": C, "O": O, "k": k, "s": s,
                     "H": c["H"], "W": c["W"], "Ho": Ho, "Wo": Wo,
                     "macs": macs, "padded_macs": padded, "beats": padded // 256,
                     "w_bytes": w_bytes, "isa": isa,
                     "max_abs_acc": OVERFLOW.get(c["name"], 0)})
    return rows

# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=str(ROOT / "runs" / "s3_qat" / "last.pt"))
    ap.add_argument("--out", default=str(HERE))
    ap.add_argument("--tag", default="tb96")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    model, ck = load_model(args.ckpt)
    print(f"[export] ckpt={args.ckpt} epoch={ck.get('epoch')}")
    build_wq_and_scales(model)

    # ---- tb96 合成输入（对齐 V1.0：(x+y+c*37)%256）
    H = W = 96
    yy, xx = np.meshgrid(np.arange(H), np.arange(W), indexing="ij")
    tb = np.stack([(xx + yy + c * 37) % 256 for c in range(3)]).astype(np.int16)

    dets, boxes, zmat = forward_int(tb, H, W)
    print(f"[export] tb96: {len(dets)} dets；点 {len(DUMPS)}；卷积 {len(CONVS)}；add {len(ADDS)}")

    # ---- golden npy
    gdir = out / "golden_int" / args.tag
    gdir.mkdir(parents=True, exist_ok=True)
    for name, arr in DUMPS.items():
        np.save(gdir / (name + ".npy"), arr)
    meta = {name: {"bits": POINTS.get(name, (16, 1 / 255))[0],
                   "scale": POINTS.get(name, (16, 1 / 255))[1],
                   "shape": list(arr.shape)} for name, arr in DUMPS.items()}
    json.dump(meta, open(gdir / "meta.json", "w"), indent=1)
    json.dump([[round(float(v), 4) for v in row] for row in dets],
              open(out / "golden_int" / (args.tag + "_dets.json"), "w"))

    # ---- tb_vectors
    tbv = out / "tb_vectors"
    tbv.mkdir(exist_ok=True)
    with open(tbv / "input.hex", "w") as f:
        for v in tb.reshape(-1):
            f.write("%02X\n" % int(v))
    json.dump({"layout": "CHW, addr=(c*H+y)*W+x", "H": H, "W": W, "C": 3,
               "format": "每行一个 2 位十六进制字节（uint8 像素值）",
               "pattern": "(x+y+c*37)%256",
               "note": "C 模型 --dump 生成的各层 hex 同序(int16, 4位hex)"},
              open(tbv / "manifest.json", "w"), indent=1)

    # ---- bin / scales / report
    write_bin(out / "rearch_int8.bin")
    json.dump({k: {"scale": SCALE[k], "src": SCALE_SRC[k]} for k in SCALE},
              open(out / "scales.json", "w"), indent=1)
    rows = conv_stats()
    tot_mac = sum(r["macs"] for r in rows)
    tot_padded = sum(r["padded_macs"] for r in rows)
    rep = {
        "ckpt": str(args.ckpt), "epoch": ck.get("epoch"), "tag": args.tag,
        "n_convs": len(CONVS), "n_points": len(POINTS), "n_adds": len(ADDS), "n_sig": len(SIGS),
        "tot_macs": tot_mac, "tot_padded_macs": tot_padded, "tot_beats": tot_padded // 256,
        "tot_w_bytes": sum(r["w_bytes"] for r in rows),
        "isa_violations": [r["name"] + ":" + k for r in rows for k, v in r["isa"].items() if not v],
        "y13_clamp": Y13_CLAMP,
        "overflow": {k: {"max_abs_acc": v, "int48_ok": bool(v < (1 << 47))}
                     for k, v in sorted(OVERFLOW.items())},
        "worst_acc": max(OVERFLOW.items(), key=lambda kv: kv[1])[0],
        "worst_acc_val": max(OVERFLOW.values()),
        "sig": SIGS, "rounding": "round-half-up" if RHU else "floor",
        "convs": rows,
    }
    json.dump(rep, open(out / "export_report.json", "w"), indent=1, default=str)
    print(f"[export] ΣMACs={tot_mac / 1e6:.2f}M（padded {tot_padded / 1e6:.2f}M，"
          f"beats {tot_padded // 256}）；权重 {sum(r['w_bytes'] for r in rows) / 1e6:.3f}MB int8")
    print(f"[export] ISA 违规 {len(rep['isa_violations'])}；y13 钳位 {sum(Y13_CLAMP.values())}；"
          f"max|acc|={max(OVERFLOW.values())} (2^{int(math.log2(max(OVERFLOW.values())))})")
    print(f"[export] 写出 {out / 'rearch_int8.bin'} + golden_int/{args.tag}/ + tb_vectors/ + "
          f"scales.json + export_report.json")

if __name__ == "__main__":
    main()
