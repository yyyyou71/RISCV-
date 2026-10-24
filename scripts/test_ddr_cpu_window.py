#!/usr/bin/env python3
"""DDR MMIO/跨时钟回归，以及实际 RV32I 程序的 CPU→DDR 闭环。"""
import json
import sys
sys.dont_write_bytecode = True
import subprocess
from pathlib import Path
import test_ddr_block_transfer as block

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/ddr_cpu_window'


def run(command, log):
    result = subprocess.run([str(x) for x in command], cwd=OUT,
                            capture_output=True, text=True, timeout=90)
    output = result.stdout + result.stderr
    (OUT / log).write_text(output)
    if result.returncode:
        raise RuntimeError(f'{command[0]} 失败，日志：{OUT / log}\n{output[-4000:]}')
    return output


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    block.OUT = OUT
    jobs = block.generate_vectors()
    source = ROOT / 'Iverilog/TB_ddr_cpu_window.v'
    rtl = [ROOT / 'vsrc/ddr_cpu_window.v', ROOT / 'vsrc/ddr_block_transfer.v']
    base = ['iverilog', '-g2012', '-DDDR3_MODEL_SLOTS=8192', '-s', 'TB_ddr_cpu_window',
            '-y', ROOT / 'vsrc']
    run([*base, '-o', OUT / 'mmio.vvp', source, ROOT / 'vsrc/ddr3.sv'], 'compile_mmio.log')
    results = {}

    def simulate(name, binary, options):
        output = run(['vvp', OUT / binary, f'+JOBS={jobs}', '+ddr3_init_cycles=1000', *options], name+'.log')
        summary = [line for line in output.splitlines() if line.startswith('PASS ')]
        if len(summary) != 1:
            raise RuntimeError(f'{name} 缺少通过标记')
        results[name] = dict(passed=True, summary=summary[0], plusargs=options)
        print(name + ': ' + summary[0], flush=True)

    run([*base, '-PTB_ddr_cpu_window.WINDOW_ENABLE=0', '-o', OUT / 'disabled.vvp',
         source, ROOT / 'vsrc/ddr3.sv'], 'compile_disabled.log')
    simulate('disabled_uart', 'disabled.vvp', [])
    simulate('cpu25_ddr131', 'mmio.vvp', [])
    simulate('cpu50_ddr131_stalled', 'mmio.vvp', ['+cpu_half_ns=10',
             '+ddr3_random_stalls=1', '+ddr3_stall_every=7', '+ddr3_stall_cycles=2'])
    # CPU 高于 DDR 频率，同步握手仍需正确；这里只验证协议，不代表实板频率能力。
    simulate('cpu166_ddr80', 'mmio.vvp', ['+cpu_half_ns=3', '+ddr3_core_period_ns=12.5',
             '+ddr3_read_latency=0', '+ddr3_write_latency=0'])

    elf = OUT / 'test.elf'
    run(['riscv64-unknown-elf-gcc', '-march=rv32i', '-mabi=ilp32', '-msmall-data-limit=0',
         '-ffreestanding', '-nostdlib', '-nostartfiles', '-O1', '-T', ROOT / 'link.ld',
         '-o', elf, ROOT / 'asm/start.s', ROOT / 'csrc/software/ddr_window_test.c'], 'build_cpu.log')
    run(['riscv64-unknown-elf-objcopy', '-j', '.text', '-O', 'binary', elf, OUT / 'test.bin'], 'objcopy.log')
    data = (OUT / 'test.bin').read_bytes()
    (OUT / 'test.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4], "little"):08x}\n'
                                        for i in range(0, len(data), 4)))
    (OUT / 'test.data').write_text('00\n')
    run([*base, '-PTB_ddr_cpu_window.CPU_TEST=1', f'-DPROG_FILE="{OUT / "test.hex"}"',
         f'-DDATA_FILE="{OUT / "test.data"}"', '-o', OUT / 'cpu.vvp', source, ROOT / 'vsrc/ddr3.sv'],
        'compile_cpu.log')
    simulate('rv32i_cpu25', 'cpu.vvp', [])
    simulate('rv32i_cpu50_stalled', 'cpu.vvp', ['+cpu_half_ns=10', '+ddr3_random_stalls=1'])
    run(['verilator', '--lint-only', '-Wall', '--top-module', 'ddr_cpu_window', *rtl], 'lint.log')
    results['lint'] = dict(passed=True)
    # 原外设采用同步复位，新窗口有异步置位/同步释放链；共享 rst_n 是有意的。
    # 此处只关闭跨模块的复位类型提示及旧模块的 timescale 提示。
    run(['verilator', '--lint-only', '-Wall', '-Wno-TIMESCALEMOD', '-Wno-SYNCASYNCNET',
         '--top-module', 'peripheral_bus', '-GENABLE_DDR=1',
         ROOT / 'vsrc/peripheral_bus.v', *rtl, ROOT / 'vsrc/uart_tx.v'], 'lint_peripheral.log')
    results['peripheral_lint'] = dict(passed=True)
    (OUT / 'result.json').write_text(json.dumps(dict(jobs=jobs, rom_bytes=len(data), results=results), indent=2)+'\n')
    print(f'RV32I 测试代码 {len(data)} 字节；日志：{OUT}')


if __name__ == '__main__':
    main()
