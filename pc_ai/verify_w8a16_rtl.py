#!/usr/bin/env python3
"""用原 C 卷积函数生成期望值并对拍 W8A16 RTL；不执行完整检测网络。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=ROOT.parent/'materials/TridentVision')
    parser.add_argument('--out', type=Path, default=ROOT/'pc_ai/outputs/w8a16_rtl')
    parser.add_argument('--prepare-only', action='store_true', help='生成 C 向量、编译 RTL，仿真由用户稍后启动')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ref = args.reference.resolve()
    weights = ref/'training/export/rearch_int8.bin'
    def run(command, name):
        result = subprocess.run([str(v) for v in command], cwd=out, capture_output=True, text=True, timeout=60)
        log = result.stdout + result.stderr
        (out/(name+'.log')).write_text(log)
        if result.returncode:
            raise RuntimeError(name+' failed:\n'+log[-5000:])
        return log
    run(['gcc', '-O2', '-std=c11', '-DTRIDENT_SOURCE='+json.dumps(str(ref/'training/export/rearch_fixed.c')),
         '-I', ref/'c_model', ROOT/'pc_ai/w8a16_vectors.c', '-lm', '-o', out/'vectors'], 'compile_c')
    run([out/'vectors', weights], 'generate_c')
    counts = json.loads((out/'counts.json').read_text())
    rtl = [ROOT/'vsrc'/f'{name}.v' for name in
           ('conv2d_w8a16_core', 'conv_mac_tile', 'multiply_adder_w8a16', 'multiply_adder', 'requant_q13')]
    for top in ('TB_requant_q13', 'TB_conv2d_w8a16_core'):
        run(['iverilog', '-g2012', '-s', top, '-o', out/(top+'.vvp'), ROOT/'Iverilog'/f'{top}.v', *rtl], 'compile_'+top)
    for top in ('requant_q13', 'conv2d_w8a16_core'):
        run(['verilator', '--lint-only', '-Wall', '--top-module', top, *rtl], 'lint_'+top)
    if args.prepare_only:
        print(f'已准备 {counts["cases"]} 个卷积输出块、{counts["quant_vectors"]} 个量化向量：{out}')
        print('运行同一命令并去掉 --prepare-only 开始仿真。')
        return
    results = {}
    for top, options in [('TB_requant_q13', [f'+COUNT={counts["quant_vectors"]}']),
                         ('TB_conv2d_w8a16_core', [f'+CASES={counts["cases"]}', f'+WORDS={counts["input_words"]}'])]:
        log = run(['vvp', out/(top+'.vvp'), *options], top)
        lines = [line for line in log.splitlines() if line.startswith('PASS ')]
        if len(lines) != 1:
            raise RuntimeError('missing PASS: '+top)
        print(lines[0], flush=True)
        results[top] = lines[0]
    report = dict(passed=True, **counts, results=results,
                  weights_sha256=hashlib.sha256(weights.read_bytes()).hexdigest(),
                  golden_source='original C conv_layer, real weights with small synthetic input tensors',
                  full_connected_network=False, ddr_connected=False, vendor_ip_verified=False)
    (out/'result.json').write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')


if __name__ == '__main__':
    main()
