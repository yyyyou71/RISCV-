#!/usr/bin/env python3
"""连续供数、跨块部分和、缓存复用、流水暂停、输出反压和复位。"""
import json
import random
import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/conv_mac_tile'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    rng=random.Random(0x4A2);jobs=20
    inputs=[];weights=[];initials=[];golden=[]
    for j in range(jobs):
        x=[rng.randrange(-128,128) for _ in range(144)]
        if j%3==0:w=[[rng.randrange(-128,128) for _ in range(144)]for _ in range(4)]
        ini=[rng.randrange(-(1<<40),1<<40)for _ in range(4)]
        n=16 if j%2==0 else 144
        sums=[ini[l]+sum(x[i]*w[l][i] for i in range(n))for l in range(4)]
        def pack(values,bits):return sum((v&((1<<bits)-1))<<(i*bits)for i,v in enumerate(values))
        inputs.extend(pack(x[i:i+16],8)for i in range(0,144,16))
        for lane in w:weights.extend(pack(lane[i:i+16],8)for i in range(0,144,16))
        initials.append(pack(ini,64));golden.append(pack(sums,64))
    for name,values,digits in [('inputs',inputs,32),('weights',weights,32),('initials',initials,64),('golden',golden,64)]:
        (OUT/(name+'.mem')).write_text(''.join(f'{v:0{digits}x}\n'for v in values))
    def run(args,log):
        r=subprocess.run([str(x)for x in args],cwd=OUT,capture_output=True,text=True,timeout=90)
        s=r.stdout+r.stderr;(OUT/log).write_text(s)
        if r.returncode:raise RuntimeError(s[-4000:])
        return s
    rtl=[ROOT/('vsrc/'+x+'.v')for x in ('conv_mac_tile','multiply_adder')]
    run(['iverilog','-g2012','-Wall','-s','TB_conv_mac_tile','-o',OUT/'test.vvp',ROOT/'Iverilog/TB_conv_mac_tile.v',*rtl],'compile.log')
    s=run(['vvp',OUT/'test.vvp',f'+JOBS={jobs}'],'simulation.log')
    if not any(x.startswith('PASS ')for x in s.splitlines()):raise RuntimeError('missing PASS')
    run(['verilator','--lint-only','-Wall','--top-module','conv_mac_tile',*rtl],'lint.log')
    (OUT/'result.json').write_text(json.dumps(dict(passed=True,cases=21,outputs=84))+'\n')
    print(s,end='')
if __name__=='__main__':main()
