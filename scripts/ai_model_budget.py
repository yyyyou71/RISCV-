#!/usr/bin/env python3
"""Structural budget for YOLOv5n v7.0; no training/runtime dependency.

Source: https://github.com/ultralytics/yolov5/blob/v7.0/models/yolov5n.yaml
Counts dense convolution MACs only, after BN folding. Timing is a compute lower
bound, excluding memory, activation, graph operations, and postprocessing.
"""
import argparse
import json
import math
from pathlib import Path


def budget(size, classes, lanes, mhz):
    layers = []

    def conv(name, shape, cout, kernel, stride=1, padding=None):
        h, w, cin = shape
        if padding is None:
            padding = kernel // 2
        ho = (h + 2 * padding - kernel) // stride + 1
        wo = (w + 2 * padding - kernel) // stride + 1
        weights = cin * cout * kernel * kernel
        macs = ho * wo * weights
        slots = ho * wo * kernel * kernel * math.ceil(cin / lanes) * lanes * math.ceil(cout / lanes) * lanes
        layers.append(dict(name=name, input=list(shape), output=[ho, wo, cout],
                           kernel=kernel, stride=stride, padding=padding, weights=weights,
                           fused_biases=cout, macs=macs, padded_mac_slots=slots))
        return ho, wo, cout

    def cat(*shapes):
        assert len({s[:2] for s in shapes}) == 1
        return *shapes[0][:2], sum(s[2] for s in shapes)

    def c3(name, shape, cout, repeats):
        hidden = cout // 2
        left = conv(name + '.cv1', shape, hidden, 1)
        right = conv(name + '.cv2', shape, hidden, 1)
        for i in range(repeats):
            left = conv(f'{name}.m.{i}.cv1', left, hidden, 1)
            left = conv(f'{name}.m.{i}.cv2', left, hidden, 3)
        return conv(name + '.cv3', cat(left, right), cout, 1)

    def up(shape):
        h, w, channels = shape
        return h * 2, w * 2, channels

    x = conv('0', (size, size, 3), 16, 6, 2, 2)
    x = conv('1', x, 32, 3, 2)
    x = c3('2', x, 32, 1)
    x = conv('3', x, 64, 3, 2)
    p3 = c3('4', x, 64, 2)
    x = conv('5', p3, 128, 3, 2)
    p4 = c3('6', x, 128, 3)
    x = conv('7', p4, 256, 3, 2)
    x = c3('8', x, 256, 1)
    x = conv('9.cv1', x, 128, 1)
    x = conv('9.cv2', cat(x, x, x, x), 256, 1)
    p5 = conv('10', x, 128, 1)
    x = c3('13', cat(up(p5), p4), 128, 1)
    neck_p4 = conv('14', x, 64, 1)
    out3 = c3('17', cat(up(neck_p4), p3), 64, 1)
    x = conv('18', out3, 64, 3, 2)
    out4 = c3('20', cat(x, neck_p4), 128, 1)
    x = conv('21', out4, 128, 3, 2)
    out5 = c3('23', cat(x, p5), 256, 1)
    heads = [conv(f'24.{i}', s, 3 * (classes + 5), 1)
             for i, s in enumerate([out3, out4, out5])]
    total = sum(l['macs'] for l in layers)
    slots = sum(l['padded_mac_slots'] for l in layers)
    peak = lanes * lanes * mhz * 1e6
    return dict(model='YOLOv5n v7.0', input_size=size, classes=classes,
                convolution_count=len(layers), convolution_macs=total,
                int8_weight_bytes=sum(l['weights'] for l in layers),
                fused_bias_count=sum(l['fused_biases'] for l in layers),
                max_single_tensor_int16_bytes=max(math.prod(l['output']) * 2 for l in layers),
                max_single_tensor_note='Excludes concat tensors, retained branches, padding, and partial sums.',
                head_shapes=[list(h) for h in heads],
                raw_candidate_count=sum(h * w * 3 for h, w, _ in heads),
                padded_mac_slots=slots, array_lanes=lanes, clock_assumption_mhz=mhz,
                compute_lower_bound_ms=1000 * total / peak,
                padded_compute_lower_bound_ms=1000 * slots / peak,
                timing_note='Analytical lower bounds, not measured latency or guaranteed FPS.',
                layers=layers)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--size', type=int, default=160)
    parser.add_argument('--classes', type=int, default=1)
    parser.add_argument('--lanes', type=int, default=8)
    parser.add_argument('--mhz', type=float, default=50)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.size < 32 or args.size % 32 or min(args.classes, args.lanes, args.mhz) <= 0:
        parser.error('size must be a positive multiple of 32; classes, lanes, and MHz must be positive')
    result = budget(args.size, args.classes, args.lanes, args.mhz)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'layers'}, indent=2))


if __name__ == '__main__':
    main()
