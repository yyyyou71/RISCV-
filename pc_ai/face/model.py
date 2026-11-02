"""保留96输入、80物理类别通道、reg_max=1及原有72个部署卷积。"""
import copy
import math
from pathlib import Path

import numpy as np
import torch

from .assets import read_y26f
from .vendor import patches, qat

VENDOR = Path(__file__).resolve().parent / 'vendor'
PROFILE = 'rearch-v1-nc80-96-w8a16-face0'
PREPROCESS = 'hdmi1920x1080-adaptive96-rne-rgb-v1'


def build_model(device='cpu', quantized=False):
    import ultralytics
    if ultralytics.__version__ != '8.4.115':
        raise RuntimeError('此训练链已固定ultralytics==8.4.115，请使用工程Conda环境')
    patches.apply_all(verbose=False)
    from ultralytics.nn.tasks import DetectionModel
    from ultralytics.cfg import DEFAULT_CFG
    model = DetectionModel(str(VENDOR / 'yolo26m_fpga.yaml'), ch=3, nc=80, verbose=False)
    model.args = copy.deepcopy(DEFAULT_CFG)
    model.names = {i: 'face' if i == 0 else f'unused_{i}' for i in range(80)}
    if quantized:
        qat.apply_qat(model, verbose=False)
    return model.to(device)


def check_structure(model, asset):
    from ultralytics.nn.modules.conv import Conv
    modules = dict(model.named_modules())
    for name, record in asset['convs'].items():
        m = modules[name]
        conv = m.conv if isinstance(m, Conv) else m
        if (list(conv.weight.shape) != record['shape'] or conv.groups != 1 or
                list(conv.stride) != [record['stride']] * 2 or list(conv.padding) != [record['pad']] * 2):
            raise ValueError('模型与已部署权重形状不同：' + name)
        if isinstance(m, Conv) and record['act'] != isinstance(m.act, torch.nn.ReLU):
            raise ValueError('模型激活与部署资产不同：' + name)
    if any(isinstance(m, torch.nn.SiLU) for m in model.modules()):
        raise ValueError('模型混入SiLU')
    if any(isinstance(m, torch.nn.Conv2d) and m.groups != 1 for m in model.modules()):
        raise ValueError('模型混入分组/深度卷积')
    head = modules['model.23']
    if head.nc != 80 or head.reg_max != 1 or not head.end2end:
        raise ValueError('检测头不符合板级配置')
    if modules['model.9'].n != 1 or not modules['model.9'].add:
        raise ValueError('SPPF必须是一次池化且带残差')
    return dict(deployment_convs=72, physical_classes=80, active_classes={'0': 'face'},
                input=[96, 96, 3], anchors=189, parameters=sum(p.numel() for p in model.parameters()),
                note='训练还包含one2many辅助头；部署只导出one2one')


@torch.no_grad()
def initialize_from_bin(model, asset, reset_classifier=True):
    """从整数资产近似恢复折叠权重，不等同于恢复浮点检查点或优化器。"""
    from ultralytics.nn.modules.conv import Conv
    modules = dict(model.named_modules())
    check_structure(model, asset)
    for name, r in asset['convs'].items():
        group = r['groups'][0]
        # 文件不保存原始s_w；由multM ~= s_w*s_x*8192*2^shift近似还原。
        scale_w = np.ldexp(group['mult'].astype(np.float64), -group['shift']) / (group['scale'] * 8192)
        w = torch.from_numpy((r['weight'].astype(np.float64) * scale_w[:, None, None, None]).astype(np.float32))
        bias = torch.from_numpy(r['bias'].astype(np.float32) / 8192)
        m = modules[name]
        if isinstance(m, Conv):
            m.conv.weight.copy_(w)
            m.bn.running_mean.zero_()
            m.bn.running_var.fill_(1)
            m.bn.weight.fill_(math.sqrt(1 + m.bn.eps))
            m.bn.bias.copy_(bias)
            m.bn.num_batches_tracked.zero_()
        else:
            m.weight.copy_(w)
            m.bias.copy_(bias)
    head = modules['model.23']
    head.cv2.load_state_dict(head.one2one_cv2.state_dict())
    head.cv3.load_state_dict(head.one2one_cv3.state_dict())
    if reset_classifier:
        for branch in (head.cv3, head.one2one_cv3):
            for scale in branch:
                torch.nn.init.normal_(scale[2].weight, std=0.01)
                scale[2].bias.fill_(-10)
                scale[2].bias[0] = -3
    return dict(method='approximate_dequantization', source_sha256=asset['sha256'],
                original_float_checkpoint=False, restored_optimizer=False,
                reset_classification_outputs=reset_classifier)


def load_checkpoint(path, device='cpu'):
    # 本项目保存state_dict而非动态补丁的完整Python模型。
    ck = torch.load(path, map_location='cpu', weights_only=False)
    if ck.get('profile') != PROFILE or ck.get('preprocess') != PREPROCESS:
        raise ValueError('检查点结构/预处理配置不符合本训练入口')
    model = build_model(device, ck['qat'])
    model.load_state_dict(ck['model'], strict=True)
    return model, ck
