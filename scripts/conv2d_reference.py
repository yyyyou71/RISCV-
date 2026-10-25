#!/usr/bin/env python3
"""整数卷积定义；不依赖 Torch，不隐式截断、量化或激活。"""
from dataclasses import dataclass


@dataclass(frozen=True)
class ConvConfig:
    height: int
    width: int
    in_channels: int
    out_channels: int
    kernel: int = 3
    stride: int = 1
    padding: int = 1
    bias_enable: bool = True

    def output_shape(self):
        dimensions = (self.height, self.width, self.in_channels, self.out_channels)
        if any(not 1 <= value <= 65535 for value in dimensions):
            raise ValueError('尺寸和通道数必须为 1..65535')
        if self.kernel not in (1, 3) or self.stride not in (1, 2) or self.padding not in (0, 1):
            raise ValueError('仅支持 K=1/3、stride=1/2、padding=0/1')
        height = (self.height + 2*self.padding - self.kernel) // self.stride + 1
        width = (self.width + 2*self.padding - self.kernel) // self.stride + 1
        if height <= 0 or width <= 0:
            raise ValueError('输入加 padding 后小于卷积核')
        return height, width, self.out_channels


def conv2d(config, image, weights, biases, act_width=8, weight_width=8):
    """输入/输出按 HWC，权重按 O-KY-KX-I；深度学习惯例，不翻转卷积核。

    输入为零点已经归零的有符号整数；bias 必须位于 input×weight 的累加尺度。
    Python 整数保留完整精度，作为 RTL 的独立数学参考。
    """
    oh, ow, oc = config.output_shape()
    if not 2 <= act_width <= 16 or not 2 <= weight_width <= 16:
        raise ValueError('操作数位宽必须为 2..16')
    if len(image) != config.height * config.width * config.in_channels:
        raise ValueError('输入长度错误')
    if len(weights) != oc * config.kernel**2 * config.in_channels or len(biases) != oc:
        raise ValueError('权重或偏置长度错误')
    for values, width in ((image, act_width), (weights, weight_width), (biases, 32)):
        if any(not -(1 << (width-1)) <= value < (1 << (width-1)) for value in values):
            raise ValueError('操作数超出有符号位宽')
    result = []
    for y in range(oh):
        for x in range(ow):
            for channel in range(oc):
                total = biases[channel] if config.bias_enable else 0
                for ky in range(config.kernel):
                    for kx in range(config.kernel):
                        iy = y*config.stride + ky - config.padding
                        ix = x*config.stride + kx - config.padding
                        if 0 <= iy < config.height and 0 <= ix < config.width:
                            for ci in range(config.in_channels):
                                index = (iy*config.width + ix)*config.in_channels + ci
                                wi = ((channel*config.kernel + ky)*config.kernel + kx)*config.in_channels + ci
                                total += image[index] * weights[wi]
                result.append(total)
    return result
