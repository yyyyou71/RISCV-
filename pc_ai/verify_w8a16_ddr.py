#!/usr/bin/env python3
"""W8A16 DDR及真实RV32I两层闭环；数学期望值来自参考工程C卷积。"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=ROOT.parent/'materials/TridentVision')
    parser.add_argument('--out', type=Path, default=ROOT/'pc_ai/outputs/w8a16_ddr')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--grouped-cpu', action='store_true', help='将CPU第二层改成补充的两尺度配置，验证非零AI_GROUP跨域')
    parser.add_argument('--profiles', choices=['normal', 'all', 'clocks'], default='normal',
                        help='all增加停顿、零延迟和不同时钟组合；clocks只补充两组非整数频率比的CPU测试')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ref = args.reference.resolve()
    def run(command, path, name):
        r = subprocess.run([str(v) for v in command], cwd=path, capture_output=True, text=True, timeout=120)
        log = r.stdout+r.stderr
        (path/(name+'.log')).write_text(log)
        if r.returncode:
            raise RuntimeError(name+' failed:\n'+log[-5000:])
        return log
    run(['gcc', '-O2', '-std=c11', '-DTRIDENT_SOURCE='+json.dumps(str(ref/'training/export/rearch_fixed.c')),
         '-I', ref/'c_model', ROOT/'pc_ai/w8a16_ddr_vectors.c', '-lm', '-o', out/'vectors'], out, 'compile_c')
    counts = {}
    for mode in ('engine', 'cpu'):
        path = out/mode
        path.mkdir(exist_ok=True)
        run([out/'vectors', ref/'training/export/rearch_int8.bin', 'cpu_groups' if mode=='cpu' and args.grouped_cpu else mode], path, 'generate_c')
        counts[mode] = json.loads((path/'counts.json').read_text())
    engine = out/'engine'
    run(['iverilog', '-g2012', '-s', 'TB_conv2d_ddr_engine', '-y', ROOT/'vsrc', '-DDDR3_MODEL_SLOTS=8192',
         '-PTB_conv2d_ddr_engine.QUANT_TEST=2', '-o', engine/'test.vvp', ROOT/'Iverilog/TB_conv2d_ddr_engine.v',
         ROOT/'vsrc/ddr3.sv'], engine, 'compile')
    cpu = out/'cpu'
    lib = subprocess.check_output(['riscv64-unknown-elf-gcc', '-march=rv32i', '-mabi=ilp32', '-print-libgcc-file-name'], text=True).strip()
    run(['riscv64-unknown-elf-gcc', '-march=rv32i', '-mabi=ilp32', '-msmall-data-limit=0', '-ffreestanding',
         '-nostdlib', '-nostartfiles', '-O1', '-T', ROOT/'link.ld', '-o', cpu/'test.elf', ROOT/'asm/start.s',
         ROOT/'csrc/software/conv2d_w8a16_test.c', lib], cpu, 'build_program')
    run(['riscv64-unknown-elf-objcopy', '-j', '.text', '-O', 'binary', cpu/'test.elf', cpu/'test.bin'], cpu, 'objcopy')
    binary = (cpu/'test.bin').read_bytes()
    if len(binary)>32768:
        raise RuntimeError('ROM exceeds 32 KiB')
    (cpu/'test.hex').write_text(''.join(f'{int.from_bytes(binary[n:n+4],"little"):08x}\n' for n in range(0,len(binary),4)))
    (cpu/'test.data').write_text('00\n')
    run(['iverilog', '-g2012', '-I', ROOT/'Iverilog', '-s', 'TB_ddr_cpu_window', '-y', ROOT/'vsrc',
         '-DDDR3_MODEL_SLOTS=8192', '-DAI_PROGRAM', '-DAI_CHAIN', '-DAI_W8A16',
         '-PTB_ddr_cpu_window.CPU_TEST=1', '-PTB_ddr_cpu_window.AI_ENABLE=1', '-PTB_ddr_cpu_window.AI_ACT_WIDTH=16',
         f'-DPROG_FILE="{cpu / "test.hex"}"', f'-DDATA_FILE="{cpu / "test.data"}"',
         '-o', cpu/'test.vvp', ROOT/'Iverilog/TB_ddr_cpu_window.v', ROOT/'vsrc/ddr3.sv'], cpu, 'compile')
    rtl = [ROOT/'vsrc'/f'{name}.v' for name in ('conv2d_ddr_engine', 'ddr_chunk_client', 'conv_mac_tile',
           'multiply_adder', 'multiply_adder_w8a16', 'requant_q13', 'requant_int8', 'add_int16')]
    for width in (8,16):
        run(['verilator', '--lint-only', '-Wall', '--top-module', 'ddr_cpu_window', '-GENABLE_AI=1',
             f'-GAI_ACT_WIDTH={width}', ROOT/'vsrc/ddr_cpu_window.v', ROOT/'vsrc/ddr_block_transfer.v', *rtl], out, 'lint_'+str(width))
    if args.prepare_only:
        print(f'已准备DDR测试{counts["engine"]["layers"]}层和真实CPU连续2层；ROM={len(binary)}字节。')
        print('去掉 --prepare-only 开始仿真；--profiles all 执行更多时钟与停顿配置。')
        return
    results = {}
    profiles = {} if args.profiles=='clocks' else {'normal': []}
    if args.profiles=='all':
        profiles.update(stalled=['+ddr3_random_stalls=1'], zero_latency=['+ddr3_read_latency=0', '+ddr3_write_latency=0'])
    for name, options in profiles.items():
        c = counts['engine']
        log = run(['vvp', engine/'test.vvp', f'+JOBS={c["layers"]}', f'+INITIAL={c["initial_words"]}',
                   f'+GOLDEN={c["golden_words"]}', *options], engine, name)
        lines = [line for line in log.splitlines() if line.startswith('PASS ')]
        if len(lines)!=1:
            raise RuntimeError('missing engine PASS')
        print(name+': '+lines[0], flush=True)
        results['engine_'+name] = lines[0]
    profiles = {} if args.profiles=='clocks' else {'cpu25': []}
    if args.profiles=='all':
        profiles['cpu50_stalled'] = ['+cpu_half_ns=10', '+ddr3_random_stalls=1']
    if args.profiles in ('all', 'clocks'):
        profiles['cpu71_ddr166_stalled'] = ['+cpu_half_ns=7', '+ddr3_core_period_ns=6', '+ddr3_random_stalls=1']
        profiles['cpu166_ddr80_zero'] = ['+cpu_half_ns=3', '+ddr3_core_period_ns=12.5',
                                        '+ddr3_read_latency=0', '+ddr3_write_latency=0']
    clock_settings = {}
    for name, options in profiles.items():
        c = counts['cpu']
        log = run(['vvp', cpu/'test.vvp', f'+WIDE_INITIAL={c["initial_words"]}',
                   f'+WIDE_GOLDEN={c["golden_words"]}', *options], cpu, name)
        lines = [line for line in log.splitlines() if line.startswith('PASS ')]
        if len(lines)!=1:
            raise RuntimeError('missing CPU PASS')
        print(name+': '+lines[0], flush=True)
        results[name] = lines[0]
        clock_settings[name] = options or ['CPU half=20ns; DDR period=7.619ns']
    report = dict(passed=True, profiles=args.profiles, fixtures=counts, results=results, rom_bytes=len(binary),
                  cpu_loaded_assets=False, cpu_scheduled=True, connected_layers=2, full_detection_network=False,
                  physical_ip_verified=False, pds_verified=False, clock_settings=clock_settings, grouped_cpu=args.grouped_cpu)
    (out/('clocks_result.json' if args.profiles=='clocks' else 'result.json')).write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')


if __name__=='__main__':
    main()
