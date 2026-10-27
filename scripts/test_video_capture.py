#!/usr/bin/env python3
"""按需抓帧/IP接口FIFO的短测试；不运行整网或CoreMark。"""
import argparse
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/video_capture'


def run(command, name):
    begin = time.monotonic()
    result = subprocess.run([str(x) for x in command], cwd=OUT,
                            capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    (OUT / (name + '.log')).write_text(output)
    if result.returncode:
        raise RuntimeError(f'{name} 失败，日志：{OUT / (name + ".log")}\n{output[-4000:]}')
    return output, time.monotonic() - begin


def compile_tb(top, binary, sources, options=()):
    run(['iverilog', '-g2012', '-s', top, '-y', ROOT / 'vsrc',
         '-DDDR3_MODEL_SLOTS=8192', *options, '-o', OUT / binary, *sources], 'compile_' + binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fifo-only', action='store_true', help='只验证FIFO行为模型、预读封装及IP分支绑定')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    results = {}

    def simulate(name, binary, options=()):
        output, seconds = run(['vvp', OUT / binary, *options], name)
        passed = [line for line in output.splitlines() if line.startswith('PASS ')]
        if len(passed) != 1:
            raise RuntimeError(f'{name} 缺少完整PASS标记')
        results[name] = dict(passed=True, summary=passed[0], host_seconds=seconds, plusargs=list(options))
        print(f'{name}: {passed[0]}', flush=True)

    fifo_tb = ROOT / 'Iverilog/TB_video_fifo.v'
    compile_tb('TB_pango_video_fifo', 'fifo_native.vvp', [fifo_tb])
    simulate('fifo_native', 'fifo_native.vvp')
    compile_tb('TB_video_fifo_adapter', 'fifo_adapter.vvp', [fifo_tb])
    simulate('fifo_adapter', 'fifo_adapter.vvp')
    # 只检查切换分支的固定IP端口绑定，不冒充真实厂商库验证。
    compile_tb('TB_video_fifo_adapter', 'fifo_ip_ports.vvp',
               [fifo_tb, ROOT / 'Iverilog/video_fifo_ip_stub.v'], ['-DUSE_PANGO_VIDEO_FIFO_IP'])
    simulate('fifo_ip_ports_stub', 'fifo_ip_ports.vvp')

    if not args.fifo_only:
        sources = [ROOT / 'Iverilog/TB_video_capture.v', ROOT / 'vsrc/ddr3.sv']
        compile_tb('TB_video_capture', 'host.vvp', sources)
        simulate('cpu25_ddr131_pixel100', 'host.vvp')
        simulate('cpu71_ddr166_pixel74_stalls', 'host.vvp', [
            '+cpu_half_ns=7', '+pixel_half_ns=7', '+ddr3_core_period_ns=6',
            '+ddr3_random_stalls=1', '+ddr3_stall_every=7', '+ddr3_stall_cycles=2'])
        # 16字小FIFO反复绕圈；该深度只用于压测，真实IP默认512字。
        compile_tb('TB_video_capture', 'small.vvp', sources, ['-PTB_video_capture.FIFO_BITS=4'])
        simulate('fifo_wraps', 'small.vvp', ['+pixel_half_ns=8'])
        simulate('overflow_recovery', 'small.vvp', ['+CASE=1', '+ddr3_core_period_ns=40',
                 '+ddr3_stall_every=32', '+ddr3_stall_cycles=24'])
        for name, case in [('no_frame', 2), ('pixel_clock_stopped', 3), ('ddr_timeout', 4),
                           ('input_timeout_active_burst', 5)]:
            simulate(name, 'host.vvp', [f'+CASE={case}'])
        compile_tb('TB_video_capture', 'host_ip_ports.vvp', [*sources, ROOT / 'Iverilog/video_fifo_ip_stub.v'],
                   ['-DUSE_PANGO_VIDEO_FIFO_IP'])
        simulate('capture_ip_ports_stub', 'host_ip_ports.vvp')

        elf = OUT / 'cpu.elf'
        library, _ = run(['riscv64-unknown-elf-gcc', '-march=rv32i', '-mabi=ilp32',
                          '-print-libgcc-file-name'], 'libgcc')
        run(['riscv64-unknown-elf-gcc', '-march=rv32i', '-mabi=ilp32', '-msmall-data-limit=0',
             '-ffreestanding', '-fno-builtin', '-ffunction-sections', '-fdata-sections',
             '-nostdlib', '-nostartfiles', '-O1', '-Wall', '-Wextra', '-Werror',
             '-Wl,--gc-sections', f'-Wl,-Map={OUT / "cpu.map"}', '-fstack-usage',
             '-T', ROOT / 'link.ld', '-o', elf, ROOT / 'asm/start.s',
             ROOT / 'csrc/software/video_capture.c', ROOT / 'csrc/software/video_capture_test.c',
             ROOT / 'csrc/software/ai_runtime.c', library.strip()], 'build_cpu')
        for section in ['text', 'data']:
            run(['riscv64-unknown-elf-objcopy', '-j', '.' + section, '-O', 'binary', elf,
                 OUT / ('cpu.' + section + '.bin')], 'objcopy_' + section)
        code = (OUT / 'cpu.text.bin').read_bytes()
        data = (OUT / 'cpu.data.bin').read_bytes()
        if len(code) > 32768 or len(data) > 49152:
            raise RuntimeError('CPU ROM/RAM预算不足')
        (OUT / 'cpu.hex').write_text(''.join(f'{int.from_bytes(code[i:i+4], "little"):08x}\n'
                                             for i in range(0, len(code), 4)))
        (OUT / 'cpu.data').write_text(''.join(f'{byte:02x}\n' for byte in data) or '00\n')
        compile_tb('TB_video_capture', 'cpu.vvp', sources, ['-PTB_video_capture.CPU_TEST=1',
                   f'-DPROG_FILE="{OUT / "cpu.hex"}"', f'-DDATA_FILE="{OUT / "cpu.data"}"'])
        simulate('rv32i_capture_readback', 'cpu.vvp')
        simulate('rv32i_independent_clocks_stalls', 'cpu.vvp', [
            '+cpu_half_ns=7', '+pixel_half_ns=7', '+ddr3_core_period_ns=6', '+ddr3_random_stalls=1'])
        results['firmware'] = dict(rom_bytes=len(code), data_bytes=len(data))

    run(['verilator', '--lint-only', '-Wall', '-Wno-TIMESCALEMOD', '-Wno-SYNCASYNCNET',
         '--top-module', 'video_async_fifo', '-y', ROOT / 'vsrc', ROOT / 'vsrc/video_async_fifo.v'], 'lint_fifo')
    if not args.fifo_only:
        run(['verilator', '--lint-only', '-Wall', '-Wno-TIMESCALEMOD', '-Wno-SYNCASYNCNET',
             '--top-module', 'peripheral_bus', '-GENABLE_DDR=1', '-GENABLE_VIDEO=1', '-GENABLE_AI=1',
             '-y', ROOT / 'vsrc', ROOT / 'vsrc/peripheral_bus.v'], 'lint_peripheral')
        run(['verilator', '--lint-only', '-Wall', '--top-module', 'ddr_cpu_window',
             ROOT / 'vsrc/ddr_cpu_window.v', ROOT / 'vsrc/ddr_block_transfer.v'], 'lint_video_disabled')
    results['lint'] = dict(passed=True)
    filename = 'fifo_result.json' if args.fifo_only else 'result.json'
    (OUT / filename).write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')
    print(f'结果与日志：{OUT / filename}')


if __name__ == '__main__':
    main()
