#!/usr/bin/env python3
"""DDR 块搬运回归：独立线性地址参考、真实行为模型、协议错误和超时。"""
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/ddr_block_transfer'


def run(command, log):
    result = subprocess.run([str(x) for x in command], cwd=OUT,
                            capture_output=True, text=True, timeout=90)
    output = result.stdout + result.stderr
    (OUT / log).write_text(output)
    if result.returncode:
        print(output, file=sys.stderr)
        raise RuntimeError(f'执行失败：{command[0]}，日志：{OUT / log}')
    return output


def generate_vectors():
    # 独立以线性字节偏移保存数据，不调用或复制 RTL 的地址换算函数。
    rng = random.Random(0xDD202610)
    memory = {}
    commands, data = [], []

    def write(address, length):
        words = [rng.getrandbits(128) for _ in range(length // 16)]
        if not commands:
            # 首块额外覆盖全零、全一及按字节变化的图案，检查数据位和字节通道。
            words[:4] = [0, (1 << 128) - 1,
                         int.from_bytes(bytes(range(16)), 'little'),
                         int.from_bytes(bytes(reversed(range(16))), 'little')]
        for i, word in enumerate(words):
            for lane in range(16):
                memory[address + i * 16 + lane] = (word >> (lane * 8)) & 255
        add(True, address, length, words)

    def read(address, length):
        words = [sum(memory[address + i + lane] << (lane * 8) for lane in range(16))
                 for i in range(0, length, 16)]
        add(False, address, length, words)

    def add(direction, address, length, words):
        assert address % 16 == length % 16 == 0 and 16 <= length <= 256
        assert address + length <= 1 << 29
        commands.append((int(direction) << 64) | (address << 32) | length)
        data.extend(words + [0] * (16 - len(words)))

    # 前两条也供 testbench 在各类复位后重复执行，检查恢复能力。
    write(0x100, 256)
    read(0x100, 256)
    write(0x200, 256)
    read(0x180, 256)
    write(0x180, 128)
    read(0x100, 256)
    read(0x200, 256)

    # 全部合法长度，并刻意让部分请求跨过 2 KiB 列边界。
    for beats in range(1, 17):
        address = 0x1800 - 16 * ((beats + 1) // 2)
        write(address, beats * 16)
        read(address, beats * 16)
    for address in [0, 0x7F0, 0x7E0, 0x800, 0x3FFF0, 0x1000000, 0x1FFFFF00]:
        write(address, 256)
        read(address, 256)
        read(address + 240, 16)

    # 不连续访问与局部覆盖，防止固定地址自增、重复旧结果等错误被回读掩盖。
    for index in range(120):
        address = rng.randrange(0x400, 0x1000) * 16
        length = rng.randrange(1, 17) * 16
        write(address, length)
        read(address, length)
        if index % 5 == 0 and length > 16:
            write(address + 16, length - 16)
            read(address, length)

    (OUT / 'commands.mem').write_text(''.join(f'{v:024x}\n' for v in commands))
    (OUT / 'data.mem').write_text(''.join(f'{v:032x}\n' for v in data))
    return len(commands)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = generate_vectors()
    rtl = ROOT / 'vsrc/ddr_block_transfer.v'
    run(['iverilog', '-g2012', '-Wall', '-DDDR3_MODEL_SLOTS=8192',
         '-s', 'TB_ddr_block_transfer', '-o', OUT / 'model.vvp',
         ROOT / 'Iverilog/TB_ddr_block_transfer.v', rtl, ROOT / 'vsrc/ddr3.sv'],
        'compile_model.log')
    cases = {
        'normal': [],
        'zero_latency': ['+ddr3_read_latency=0', '+ddr3_write_latency=0', '+ddr3_init_cycles=73'],
        'stalled': ['+ddr3_read_latency=11', '+ddr3_write_latency=7',
                    '+ddr3_stall_every=7', '+ddr3_stall_cycles=2',
                    '+ddr3_random_stalls=1', '+ddr3_seed=17'],
    }
    results = {}
    for name, options in cases.items():
        output = run(['vvp', OUT / 'model.vvp', f'+JOBS={jobs}', *options], f'{name}.log')
        summary = [line for line in output.splitlines() if line.startswith('PASS ')]
        if len(summary) != 1:
            raise RuntimeError(f'{name} 缺少完整通过标记')
        results[name] = dict(passed=True, plusargs=options, summary=summary[0])
        print(name + ': ' + summary[0])
    run(['iverilog', '-g2012', '-Wall', '-s', 'TB_ddr_block_transfer_faults',
         '-o', OUT / 'faults.vvp', ROOT / 'Iverilog/TB_ddr_block_transfer_faults.v', rtl],
        'compile_faults.log')
    output = run(['vvp', OUT / 'faults.vvp'], 'faults.log')
    summary = [line for line in output.splitlines() if line.startswith('PASS ')]
    if len(summary) != 1:
        raise RuntimeError('协议错误测试缺少完整通过标记')
    results['faults'] = dict(passed=True, summary=summary[0])
    print(summary[0])
    run(['verilator', '--lint-only', '-Wall', '--top-module', 'ddr_block_transfer', rtl], 'lint.log')
    results['lint'] = dict(passed=True)
    (OUT / 'result.json').write_text(json.dumps(dict(jobs=jobs, results=results), indent=2) + '\n')
    print(f'日志与向量：{OUT}')


if __name__ == '__main__':
    main()
