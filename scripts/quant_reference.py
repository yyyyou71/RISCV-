"""第一版加速器量化 ABI；Python 无限精度整数参考，不依赖 RTL 实现。"""
import struct


def requant_int8(value, multiplier, shift, relu=False):
    if not -(1 << 63) <= value < (1 << 63):
        raise ValueError('累加值必须为 INT64')
    if not 0 <= multiplier < (1 << 31) or not 0 <= shift <= 95:
        raise ValueError('倍率必须为非负 INT31，右移量必须为 0..95')
    # 对有理数做最近舍入，半整数远离零；不依赖负数右移的语言差异。
    numerator = abs(value) * multiplier
    denominator = 1 << shift
    quotient, remainder = divmod(numerator, denominator)
    rounded = quotient + int(2 * remainder >= denominator)
    result = -rounded if value < 0 else rounded
    if relu:
        result = max(0, result)
    return max(-128, min(127, result))


def quantize_hwc(values, channels, params, relu=False):
    if len(params) != channels or len(values) % channels:
        raise ValueError('通道数或量化参数长度错误')
    return [requant_int8(v, *params[i % channels], relu) for i, v in enumerate(values)]


def pack_hwc_int8(values, channels, padding=0):
    """导出 H-W-align16(C)；padding 可设毒值来验证硬件尾部处理。"""
    if len(values) % channels or any(not -128 <= v <= 127 for v in values):
        raise ValueError('HWC INT8 数据错误')
    pitch = (channels + 15) & ~15
    return b''.join(bytes(v & 255 for v in values[p:p+channels]) +
                    bytes([padding]) * (pitch-channels)
                    for p in range(0, len(values), channels))


def pack_quant_params(params):
    """每输出通道 16 字节：u32 multiplier、u32 shift、两个保留零字。"""
    records = []
    for multiplier, shift in params:
        requant_int8(0, multiplier, shift)
        records.append(struct.pack('<IIII', multiplier, shift, 0, 0))
    records.extend([bytes(16)] * ((-len(params)) % 4))
    return b''.join(records)
