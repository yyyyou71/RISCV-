#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patches.py — REARCH-v1 训练管线的两处规格书补丁（运行时应用，可回滚）
=====================================================================
规格书 YOLO26M_FPGA_REARCH_SPEC.md §5.1 的补丁①②。
**不打在 site-packages 源码上**：本模块以 monkey-patch 方式在进程内生效，
不 import 本模块即为原始环境 = 天然回滚路径。

补丁① apply_relu_patch()      : Conv.default_act SiLU→ReLU（训推一致，引擎 LUT 重烧）
补丁② apply_detect_fpga_patch(): Detect → DetectFPGA 子类注入 tasks 命名空间，
                                  cv3 DWConv → 普通 3×3 Conv（ISA 合规）
补丁③ apply_c3_fpga_patch()    : tasks.C3 → C3FPGA（Bottleneck 内层 1×1→3×3，即 k=(3,3)）
                                  ——规格书 §2.3 逐层参数表按此口径（冒烟实测对齐 11.836M）
"""
from __future__ import annotations
import copy
import torch.nn as nn

_APPLIED = []


def apply_relu_patch():
    """补丁①：全局激活 SiLU→ReLU（Conv 类属性，影响所有下游模块）。"""
    from ultralytics.nn.modules.conv import Conv
    Conv.default_act = nn.ReLU(inplace=True)
    _APPLIED.append("relu")
    return "Conv.default_act → ReLU(inplace)"


class _DetectFPGAMixin:
    """cv3 普通卷积化重建逻辑（供 DetectFPGA 使用）。"""

    def _rebuild_cv3_fpga(self, ch):
        from ultralytics.nn.modules.conv import Conv
        nc = self.nc
        c3 = max(ch[0], min(nc, 100))  # 与 Detect.__init__ 同一规则
        assert c3 % 16 == 0, f"DetectFPGA: c3={c3} 未 16 对齐"
        self.cv3 = nn.ModuleList(
            nn.Sequential(Conv(x, c3, 3), Conv(c3, c3, 3), nn.Conv2d(c3, nc, 1)) for x in ch
        )
        if getattr(self, "one2one_cv3", None) is not None:
            self.one2one_cv3 = copy.deepcopy(self.cv3)


def make_detect_fpga():
    """构造 DetectFPGA 子类（cv3 DWConv→普通 3×3）。"""
    from ultralytics.nn.modules.head import Detect

    class DetectFPGA(Detect, _DetectFPGAMixin):
        """REARCH-v1 检测头：cv3 分支普通卷积（引擎无 depthwise 支持）。
        c2/c3 通道规则与父类一致（c2=max(16,ch0//4,4·reg_max)=32、c3=max(ch0,80)=128，均 16 对齐）。
        """

        def __init__(self, nc=80, reg_max=1, end2end=True, ch=()):
            super().__init__(nc=nc, reg_max=reg_max, end2end=end2end, ch=ch)
            self._rebuild_cv3_fpga(ch)

    return DetectFPGA


def apply_detect_fpga_patch():
    """补丁②：把 DetectFPGA 注入 ultralytics.nn.tasks 命名空间，
    使 yaml 中的 `Detect` 在 parse_model 时解析到 FPGA 版。"""
    import ultralytics.nn.tasks as tasks
    tasks.Detect = make_detect_fpga()
    _APPLIED.append("detect_fpga")
    return "tasks.Detect → DetectFPGA(cv3 普通 3×3)"


def apply_c3_fpga_patch():
    """补丁③：tasks.C3 → C3FPGA，Bottleneck 双 3×3（k=(3,3)）。

    规格书 §2.3 逐层参数表按"Bottleneck cv1/cv2 均 3×3"计参（实测逐块核对：
    官方 C3 的 bottleneck 首层为 1×1，与表差 1.59M；换 k=(3,3) 后逐块对齐）。
    parse_model 对 C3 走 base_modules/repeat_modules 分支，子类注入后
    yaml 的 `C3` 名称解析不变、args 自动 insert n 的行为不变。
    """
    import ultralytics.nn.tasks as tasks
    from ultralytics.nn.modules.block import C3, Bottleneck

    class C3FPGA(C3):
        """REARCH-v1 C3：cv1/cv2/cv3 与官方一致，Bottleneck 内层 1×1→3×3。"""

        def __init__(self, c1, c2, n=1, shortcut=True, g=1, e=0.5):
            super().__init__(c1, c2, n, shortcut, g, e)
            c_ = int(c2 * e)
            self.m = nn.Sequential(*(Bottleneck(c_, c_, shortcut, g, k=(3, 3), e=1.0) for _ in range(n)))

    tasks.C3 = C3FPGA
    _APPLIED.append("c3_fpga")
    return "tasks.C3 → C3FPGA(Bottleneck 双 3×3)"


def apply_all(verbose=True):
    msgs = [apply_relu_patch(), apply_detect_fpga_patch(), apply_c3_fpga_patch()]
    if verbose:
        for m in msgs:
            print(f"[patch] {m}")
    return msgs


def applied():
    return list(_APPLIED)
