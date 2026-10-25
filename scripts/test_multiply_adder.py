#!/usr/bin/env python3
"""Multiply-Adder 行为回归：任意精度算术参考、使能时钟计数和复位脉冲。"""
import json
import random
import subprocess
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/multiply_adder'


def run(command, path, log, fail_expected=False):
    result = subprocess.run([str(x) for x in command], cwd=path,
                            capture_output=True, text=True, timeout=90)
    output = result.stdout + result.stderr
    (path / log).write_text(output)
    if fail_expected:
        if not result.returncode or 'invalid static-mode IP configuration' not in output:
            raise RuntimeError(f'非法配置没有按预期拒绝：{path / log}\n{output[-2000:]}')
    elif result.returncode:
        raise RuntimeError(f'{command[0]} 失败：{path / log}\n{output[-4000:]}')
    return output


def decode(bits, width, signed):
    if signed and bits & (1 << (width-1)):
        return bits - (1 << width)
    return bits


def generate_vectors(path, aw, bw, signed_a, signed_b):
    rng = random.Random(0xAD202610)
    ma, mb = (1 << aw)-1, (1 << bw)-1
    pw = aw+bw+1
    mp = (1 << pw)-1
    vectors = []

    def add(a0, a1, b0, b1, ce=1, rst=0, pulse=0):
        # addsub 在静态模式下应被忽略，故意随周期变化。
        vectors.append((a0 & ma, a1 & ma, b0 & mb, b1 & mb, ce, rst, pulse, rng.randrange(2)))

    # 首次同步/异步复位均在 ce=0 时进行，检查复位优先级。
    add(0, 0, 0, 0, ce=0, rst=1)
    for _ in range(7):
        add(3, 5, 2, 7)
    # 无时钟沿的短复位脉冲，随后插入流水线暂停和排空。
    add(7, 11, 5, 13, pulse=1)
    for _ in range(12):
        add(ma, ma >> 1, mb, mb >> 1, ce=0)
    for _ in range(8):
        add(0, 0, 0, 0)
    a_edges = [0, 1, 2, ma, ma-1, 1 << (aw-1), (1 << (aw-1))-1]
    b_edges = [0, 1, 2, mb, mb-1, 1 << (bw-1), (1 << (bw-1))-1]
    for a in a_edges:
        for b in b_edges:
            add(a, a, b, b)
            add(a, ma ^ a, b, mb ^ b)
            add(a, 0, b, mb)
            add(0, a, b, mb)
    for index in range(1200):
        rst = int(index % 173 == 77)
        add(rng.getrandbits(aw), rng.getrandbits(aw), rng.getrandbits(bw), rng.getrandbits(bw),
            ce=int(rng.randrange(4) != 0), rst=rst,
            pulse=int(not rst and index % 127 == 43))
    # 用不同输入持续 ce=0，检查输出/全部在途流水项均保持。
    for _ in range(37):
        add(rng.getrandbits(aw), rng.getrandbits(aw), rng.getrandbits(bw), rng.getrandbits(bw), ce=0)
    for _ in range(8):
        add(0, 0, 0, 0)

    # 状态按“接收历史”记录，而不调用 RTL 的扩展/移位实现。
    histories = {(op, ar, n): deque([0]*n, maxlen=n)
                 for op in range(2) for ar in range(2) for n in range(1, 6)}
    rows, before, after, pulse_results = [], [], [], []
    for a0, a1, b0, b1, ce, rst, pulse, addsub in vectors:
        a0v, a1v = decode(a0, aw, signed_a), decode(a1, aw, signed_a)
        b0v, b1v = decode(b0, bw, signed_b), decode(b1, bw, signed_b)
        results = [(a0v*b0v + a1v*b1v) & mp, (a0v*b0v - a1v*b1v) & mp]
        snapshots = [0, 0, 0]
        for op in range(2):
            for ar in range(2):
                for n in range(6):
                    lane = (op*2+ar)*6+n
                    if n == 0:
                        values = [results[op]]*3
                    else:
                        history = histories[op, ar, n]
                        if rst and ar:
                            history.clear(); history.extend([0]*n)
                        v_before = history[0]
                        if rst:
                            history.clear(); history.extend([0]*n)
                        elif ce:
                            history.append(results[op])
                        v_after = history[0]
                        if pulse and ar:
                            history.clear(); history.extend([0]*n)
                        values = [v_before, v_after, history[0]]
                    for phase, value in enumerate(values):
                        snapshots[phase] |= value << (lane*pw)
        control = rst | ce << 1 | addsub << 2 | pulse << 3
        rows.append(control | a0 << 4 | a1 << (4+aw) | b0 << (4+2*aw) | b1 << (4+2*aw+bw))
        before.append(snapshots[0]); after.append(snapshots[1]); pulse_results.append(snapshots[2])
    for name, values, bits in [('stimuli', rows, 2*aw+2*bw+4), ('before', before, 24*pw),
                               ('after', after, 24*pw), ('pulse', pulse_results, 24*pw)]:
        digits = (bits+3)//4
        (path / (name+'.mem')).write_text(''.join(f'{value:0{digits}x}\n' for value in values))
    return len(rows)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rtl = ROOT / 'vsrc/multiply_adder.v'
    results = {}
    # 包含 CNN 用途、手册默认位宽、混合符号、最小及手册最大边界。
    configs = [(8, 8, 1, 1), (16, 8, 1, 1), (16, 9, 1, 1), (11, 8, 0, 0),
               (8, 8, 0, 0), (8, 8, 1, 0), (8, 8, 0, 1),
               (73, 66, 1, 1), (72, 65, 0, 0), (2, 2, 1, 1)]
    for aw, bw, sa, sb in configs:
        name = f'a{aw}s{sa}_b{bw}s{sb}'
        path = OUT / name
        path.mkdir(exist_ok=True)
        rows = generate_vectors(path, aw, bw, sa, sb)
        parameters = dict(A_WIDTH=aw, B_WIDTH=bw, A_SIGNED=sa, B_SIGNED=sb)
        run(['iverilog', '-g2012', '-Wall', '-s', 'TB_multiply_adder',
             *[f'-PTB_multiply_adder.{key}={value}' for key, value in parameters.items()],
             '-o', path / 'test.vvp', ROOT / 'Iverilog/TB_multiply_adder.v', rtl], path, 'compile.log')
        output = run(['vvp', path / 'test.vvp', f'+ROWS={rows}'], path, 'simulation.log')
        summary = [line for line in output.splitlines() if line.startswith('PASS ')]
        if len(summary) != 1:
            raise RuntimeError(f'{name} 缺少通过标记')
        results[name] = dict(passed=True, rows=rows, instances=24, summary=summary[0])
        print(summary[0], flush=True)

    # 静态算术和流水线各分支分别进行严格 lint。
    for stages in range(6):
        for ar in range(2):
            for sub in range(2):
                run(['verilator', '--lint-only', '-Wall', '--top-module', 'multiply_adder',
                     f'-GPIPE_STAGES={stages}', f'-GASYNC_RESET={ar}', f'-GSTATIC_SUBTRACT={sub}', rtl],
                    OUT, f'lint_s{stages}_ar{ar}_sub{sub}.log')
    rejected = [dict(PIPE_STAGES=6), dict(PIPE_STAGES=-1), dict(A_WIDTH=1),
                dict(A_WIDTH=74), dict(B_WIDTH=67), dict(A_WIDTH=73, A_SIGNED=0),
                dict(B_WIDTH=66, B_SIGNED=0), dict(A_SIGNED=2), dict(ASYNC_RESET=2),
                dict(STATIC_SUBTRACT=2)]
    for index, parameters in enumerate(rejected):
        run(['iverilog', '-g2012', '-s', 'multiply_adder',
             *[f'-Pmultiply_adder.{key}={value}' for key, value in parameters.items()],
             '-o', OUT / 'invalid.vvp', rtl], OUT, f'compile_invalid_{index}.log')
        run(['vvp', OUT / 'invalid.vvp'], OUT, f'invalid_{index}.log', fail_expected=True)
    report = dict(results=results, lint_configs=24, rejected_configs=len(rejected),
                  total_instances=24*len(configs), mode='static_add_subtract')
    (OUT / 'result.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'PASS lint=24 invalid_configs={len(rejected)}；日志：{OUT}')


if __name__ == '__main__':
    main()
