"""读取现有Y26F部署资产；用于结构核对及可选的近似反量化初始化。"""
import hashlib
import math
from pathlib import Path
import struct

import numpy as np


def read_y26f(path):
    data = Path(path).read_bytes()
    if len(data) < 32 or struct.unpack_from('<4s7I', data) != (b'Y26F', 1, 72, 83, 10, 0, 3, 0):
        raise ValueError('需要REARCH-v1的72卷积/10ADD/3组检测头Y26F资产')
    offset = 32

    def take(fmt):
        nonlocal offset
        size = struct.calcsize(fmt)
        if offset + size > len(data):
            raise ValueError('Y26F文件截断')
        values = struct.unpack_from(fmt, data, offset)
        offset += size
        return values

    def name():
        return take('<48s')[0].split(b'\0')[0].decode('ascii')

    convs = {}
    for _ in range(72):
        nm = name()
        kind, act, ng, bits = take('<4B')
        co, ci, kh, kw, sh, sw, pad = take('<7I')
        scale, my, sy = take('<f2i')
        if (nm in convs or kind not in (0, 2) or bits != 16 or ng not in (1, 2) or
                kh != kw or kh not in (1, 3) or sh != sw or sh not in (1, 2) or
                not 0 < co <= 4096 or not 0 < ci <= 4096 or not math.isfinite(scale) or scale <= 0):
            raise ValueError('不支持的卷积记录：' + nm)
        groups = [dict(zip(('begin', 'end', 'shift', 'scale'), take('<2Iif'))) for _ in range(ng)]
        for g in groups:
            if not 0 <= g['begin'] < g['end'] <= ci or g['scale'] <= 0 or not math.isfinite(g['scale']):
                raise ValueError('无效输入尺度分组')
            g['mult'] = np.asarray(take(f'<{co}i'), dtype=np.int64)
        bias = np.asarray(take(f'<{co}i'), dtype=np.int32)
        size = co * ci * kh * kw
        if offset + size > len(data):
            raise ValueError('卷积权重截断')
        weight = np.frombuffer(data, dtype=np.int8, count=size, offset=offset).copy().reshape(co, ci, kh, kw)
        offset += size
        convs[nm] = dict(kind=kind, act=act, shape=list(weight.shape), stride=sh, pad=pad,
                         scale=scale, mult_y=my, shift_y=sy, groups=groups, bias=bias, weight=weight)
    points = {}
    for _ in range(83):
        nm = name()
        bits, scale = take('<B3xf')
        if nm in points or bits != 16 or not math.isfinite(scale) or scale <= 0:
            raise ValueError('无效量化点')
        points[nm] = scale
    adds = {}
    for _ in range(10):
        nm = name()
        bits, scale, ma, sa, mb, sb = take('<B3xf4i')
        adds[nm] = dict(bits=bits, scale=scale, mult_a=ma, shift_a=sa, mult_b=mb, shift_b=sb)
    heads = []
    for _ in range(3):
        index = take('<I')[0]
        box, cls = name(), name()
        mult, shift, sbox, scls = take('<2i2f')
        heads.append(dict(index=index, box=box, cls=cls, mult=mult, shift=shift, sbox=sbox, scls=scls))
    if offset != len(data):
        raise ValueError('Y26F尾部长度不符')
    return dict(convs=convs, points=points, adds=adds, heads=heads,
                sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
