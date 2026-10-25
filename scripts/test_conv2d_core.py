#!/usr/bin/env python3
"""可配置卷积回归：整数参考、逐项 RTL 对拍、握手停顿与共同复位。"""
import sys
sys.dont_write_bytecode = True
import json
import random
import subprocess
from pathlib import Path
from conv2d_reference import ConvConfig, conv2d

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/conv2d_core'


def run(command, path, log):
    result = subprocess.run([str(x) for x in command], cwd=path,
                            capture_output=True, text=True, timeout=90)
    output = result.stdout + result.stderr
    (path / log).write_text(output)
    if result.returncode:
        raise RuntimeError(f'{command[0]} 失败：{path / log}\n{output[-4000:]}')
    return output


def self_check_reference():
    # 用手算小例子检查参考的符号、偏置、padding 和核方向。
    assert conv2d(ConvConfig(2, 2, 1, 1, 1, 1, 0), [1, 2, 3, 4], [-3], [7]) == [4, 1, -2, -5]
    assert conv2d(ConvConfig(2, 2, 1, 1), [1, 2, 3, 4], [1]*9, [-1]) == [9]*4
    assert conv2d(ConvConfig(1, 3, 1, 1), [2, 3, 5], list(range(1, 10)), [0]) == [28, 53, 37]


def generate_vectors(path, aw, ww):
    rng = random.Random(0xC02D2026)
    images, weights, biases, expected, jobs = [], [], [], [], []
    configs = []
    for kernel in (1, 3):
        for stride in (1, 2):
            for padding in (0, 1):
                for ci, co in ((1, 1), (3, 5), (17, 3)):
                    configs.append(ConvConfig(5, 6, ci, co, kernel, stride, padding, co != 1))
    configs += [ConvConfig(1, 1, 1, 2, 1, 1, 1), ConvConfig(1, 3, 2, 3, 3, 2, 1),
                ConvConfig(3, 3, 65, 2, 3, 1, 0), ConvConfig(2, 2, 2, 3, 3, 1, 1)]
    for _ in range(40):
        kernel = rng.choice((1, 3))
        configs.append(ConvConfig(rng.randrange(3, 8), rng.randrange(3, 9),
                                  rng.randrange(1, 10), rng.randrange(1, 8), kernel,
                                  rng.choice((1, 2)), rng.choice((0, 1)), bool(rng.randrange(2))))
    for index, config in enumerate(configs):
        n_input = config.height * config.width * config.in_channels
        n_weight = config.out_channels * config.kernel**2 * config.in_channels
        values_a = [-(1 << (aw-1)), (1 << (aw-1))-1, -1, 0, 1]
        values_w = [-(1 << (ww-1)), (1 << (ww-1))-1, -1, 0, 1]
        image = [rng.choice(values_a) for _ in range(n_input)]
        weight = [rng.choice(values_w) for _ in range(n_weight)]
        bias = [rng.choice((-(1 << 31), (1 << 31)-1, -123, 0, 71)) for _ in range(config.out_channels)]
        if index == 26:
            # 非抵消的大正数部分和，特别检查宽累加和有符号扩展。
            image = [values_a[0]]*n_input
            weight = [values_w[0]]*n_weight
            bias = [(1 << 31)-1, -(1 << 31)]
        result = conv2d(config, image, weight, bias, aw, ww)
        bits = (config.height | config.width << 16 | config.in_channels << 32 |
                config.out_channels << 48 | config.kernel << 64 | config.stride << 66 |
                config.padding << 68 | int(config.bias_enable) << 70)
        job = (bits | len(images) << 128 | len(weights) << 160 | len(biases) << 192 |
               len(expected) << 224 | len(result) << 256)
        jobs.append(job)
        images.extend(image); weights.extend(weight); biases.extend(bias); expected.extend(result)
    for name, values, bits in [('jobs', jobs, 288), ('image', images, aw), ('weight', weights, ww),
                               ('bias', biases, 32), ('expected', expected, 64)]:
        # 补齐到整十六进制位；负数保留对应位宽的补码。
        digits = (bits + 3)//4
        (path / (name+'.mem')).write_text(''.join(f'{v & ((1 << bits)-1):0{digits}x}\n' for v in values))
    return dict(jobs=len(jobs), inputs=len(images), weights=len(weights),
                biases=len(biases), outputs=len(expected))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    self_check_reference()
    results = {}
    for aw, ww in ((8, 8), (16, 8), (16, 9)):
        path = OUT / f'a{aw}w{ww}'
        path.mkdir(exist_ok=True)
        sizes = generate_vectors(path, aw, ww)
        rtl = ROOT / 'vsrc/conv2d_core.v'
        run(['iverilog', '-g2012', '-Wall', '-s', 'TB_conv2d_core',
             f'-PTB_conv2d_core.ACT_WIDTH={aw}', f'-PTB_conv2d_core.WEIGHT_WIDTH={ww}',
             '-o', path / 'test.vvp', ROOT / 'Iverilog/TB_conv2d_core.v', rtl], path, 'compile.log')
        options = [f'+{name.upper()}={value}' for name, value in sizes.items()]
        output = run(['vvp', path / 'test.vvp', *options], path, 'simulation.log')
        summary = [line for line in output.splitlines() if line.startswith('PASS ')]
        if len(summary) != 1:
            raise RuntimeError(f'{path} 缺少通过标记')
        run(['verilator', '--lint-only', '-Wall', '--top-module', 'conv2d_core',
             f'-GACT_WIDTH={aw}', f'-GWEIGHT_WIDTH={ww}', rtl], path, 'lint.log')
        results[f'W{ww}A{aw}'] = dict(passed=True, summary=summary[0], **sizes)
        print(summary[0], flush=True)
    (OUT / 'result.json').write_text(json.dumps(results, indent=2)+'\n')
    print(f'整数向量和日志：{OUT}')


if __name__ == '__main__':
    main()
