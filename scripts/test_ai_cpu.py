#!/usr/bin/env python3
"""真实 RV32I：原始单层回归，以及无需 CPU 重排中间图的两层 INT8 连续计算。"""
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
def test_program(source,stem,chain=False):
    elf=OUT/(stem+'.elf');binary=OUT/(stem+'.bin');image=OUT/(stem+'.hex');datafile=OUT/(stem+'.data')
    lib=subprocess.check_output(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-print-libgcc-file-name'],text=True).strip()
    run(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-msmall-data-limit=0','-ffreestanding',
         '-nostdlib','-nostartfiles','-O1','-T',ROOT/'link.ld','-o',elf,ROOT/'asm/start.s',
         ROOT/('csrc/software/'+source),lib],stem+'_build.log')
    run(['riscv64-unknown-elf-objcopy','-j','.text','-O','binary',elf,binary],stem+'_objcopy.log')
    data=binary.read_bytes()
    image.write_text(''.join(f'{int.from_bytes(data[n:n+4],"little"):08x}\n' for n in range(0,len(data),4)))
    datafile.write_text('00\n')
    if len(data)>32768:raise RuntimeError('ROM exceeds 32 KiB')
    run(['iverilog','-g2012','-s','TB_ddr_cpu_window','-y',ROOT/'vsrc','-DDDR3_MODEL_SLOTS=8192','-DAI_PROGRAM',
         *(['-DAI_CHAIN'] if chain else []),
         '-PTB_ddr_cpu_window.CPU_TEST=1','-PTB_ddr_cpu_window.AI_ENABLE=1',
         f'-DPROG_FILE="{image}"',f'-DDATA_FILE="{datafile}"',
         '-o',OUT/(stem+'.vvp'),ROOT/'Iverilog/TB_ddr_cpu_window.v',ROOT/'vsrc/ddr3.sv'],stem+'_compile.log')
    results={}
    for name,opts in {'cpu25':[], 'cpu50_stalled':['+cpu_half_ns=10','+ddr3_random_stalls=1']}.items():
        s=run(['vvp',OUT/(stem+'.vvp'),*opts],stem+'_'+name+'.log')
        passed=[line for line in s.splitlines() if line.startswith('PASS ')]
        if len(passed)!=1:raise RuntimeError('missing PASS')
        print(stem+' '+name+': '+passed[0],flush=True);results[name]=passed[0]
    return dict(rom_bytes=len(data),results=results)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    results={}
    run(['iverilog','-g2012','-s','TB_ai_control','-y',ROOT/'vsrc','-DDDR3_MODEL_SLOTS=8192',
         '-o',OUT/'control.vvp',ROOT/'Iverilog/TB_ai_control.v',ROOT/'vsrc/ddr3.sv'],'compile_control.log')
    control=run(['vvp',OUT/'control.vvp'],'control.log')
    lines=[s for s in control.splitlines() if s.startswith('PASS ')]
    if len(lines)!=1:raise RuntimeError('missing control PASS')
    print(lines[0],flush=True);results['control']=lines[0]
    results['raw']=test_program('conv2d_ddr_test.c','raw')
    results['chain']=test_program('conv2d_chain_test.c','chain',True)
    (OUT/'result.json').write_text(json.dumps(results,indent=2)+'\n')
    print(f'RV32I ROM raw={results["raw"]["rom_bytes"]} chain={results["chain"]["rom_bytes"]} bytes')
if __name__=='__main__':main()
