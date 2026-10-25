#!/usr/bin/env python3
"""真实 RV32I 程序：窗口装载 DDR、配置并行引擎、读回两层独立任务。"""
import json
import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/ai_cpu'
def run(args,log):
    r=subprocess.run([str(x) for x in args],cwd=OUT,capture_output=True,text=True,timeout=120)
    s=r.stdout+r.stderr;(OUT/log).write_text(s)
    if r.returncode:raise RuntimeError(f'{log}\n{s[-4000:]}')
    return s
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    lib=subprocess.check_output(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-print-libgcc-file-name'],text=True).strip()
    run(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-msmall-data-limit=0','-ffreestanding',
         '-nostdlib','-nostartfiles','-O1','-T',ROOT/'link.ld','-o',OUT/'test.elf',ROOT/'asm/start.s',
         ROOT/'csrc/software/conv2d_ddr_test.c',lib],'build.log')
    run(['riscv64-unknown-elf-objcopy','-j','.text','-O','binary',OUT/'test.elf',OUT/'test.bin'],'objcopy.log')
    data=(OUT/'test.bin').read_bytes()
    (OUT/'test.hex').write_text(''.join(f'{int.from_bytes(data[n:n+4],"little"):08x}\n' for n in range(0,len(data),4)))
    (OUT/'test.data').write_text('00\n')
    run(['iverilog','-g2012','-s','TB_ddr_cpu_window','-y',ROOT/'vsrc','-DDDR3_MODEL_SLOTS=8192','-DAI_PROGRAM',
         '-PTB_ddr_cpu_window.CPU_TEST=1','-PTB_ddr_cpu_window.AI_ENABLE=1',
         f'-DPROG_FILE="{OUT/"test.hex"}"',f'-DDATA_FILE="{OUT/"test.data"}"',
         '-o',OUT/'test.vvp',ROOT/'Iverilog/TB_ddr_cpu_window.v',ROOT/'vsrc/ddr3.sv'],'compile.log')
    results={}
    run(['iverilog','-g2012','-s','TB_ai_control','-y',ROOT/'vsrc','-DDDR3_MODEL_SLOTS=8192',
         '-o',OUT/'control.vvp',ROOT/'Iverilog/TB_ai_control.v',ROOT/'vsrc/ddr3.sv'],'compile_control.log')
    control=run(['vvp',OUT/'control.vvp'],'control.log')
    lines=[s for s in control.splitlines() if s.startswith('PASS ')]
    if len(lines)!=1:raise RuntimeError('missing control PASS')
    print(lines[0],flush=True);results['control']=lines[0]
    for name,opts in {'cpu25':[], 'cpu50_stalled':['+cpu_half_ns=10','+ddr3_random_stalls=1']}.items():
        s=run(['vvp',OUT/'test.vvp',*opts],name+'.log')
        passed=[line for line in s.splitlines() if line.startswith('PASS ')]
        if len(passed)!=1:raise RuntimeError('missing PASS')
        print(name+': '+passed[0],flush=True);results[name]=passed[0]
    (OUT/'result.json').write_text(json.dumps(dict(rom_bytes=len(data),results=results),indent=2)+'\n')
    print(f'RV32I ROM={len(data)} bytes')
if __name__=='__main__':main()
