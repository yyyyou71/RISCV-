#!/usr/bin/env python3
"""4x2 IP 计算通路与真实行为 DDR 的单层逐项对拍。"""
import sys
sys.dont_write_bytecode = True
import json
import random
import subprocess
from pathlib import Path
from conv2d_reference import ConvConfig, conv2d
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/conv2d_ddr'

def run(args,log):
    r=subprocess.run([str(x) for x in args],cwd=OUT,capture_output=True,text=True,timeout=120)
    s=r.stdout+r.stderr;(OUT/log).write_text(s)
    if r.returncode: raise RuntimeError(f'{log}\n{s[-4000:]}')
    return s

def generate():
    rng=random.Random(0x4C022026)
    specs=[ConvConfig(3,3,3,5),ConvConfig(5,6,17,7),ConvConfig(2,3,1,1,1,2,0,False),
        ConvConfig(1,1,1,5,1,1,1),ConvConfig(3,4,33,9,3,2,1),ConvConfig(3,3,16,4,3,1,0),
        ConvConfig(5,8,19,6,1,2,1,False),ConvConfig(3,3,65,2,3,1,0)]
    for _ in range(8):
        specs.append(ConvConfig(rng.randrange(3,7),rng.randrange(3,8),rng.choice([2,15,16,18,31,32]),
                    rng.choice([2,3,4,6,8]),rng.choice([1,3]),rng.choice([1,2]),rng.choice([0,1]),bool(rng.randrange(2))))
    initial=[];golden=[];jobs=[]
    for index,c in enumerate(specs):
        ci=(c.in_channels+15)&~15;co=(c.out_channels+3)&~3
        x=[rng.choice([-128,-1,0,1,127]) for _ in range(c.height*c.width*c.in_channels)]
        w=[rng.choice([-128,-1,0,1,127]) for _ in range(c.out_channels*c.kernel*c.kernel*c.in_channels)]
        b=[rng.choice([-2**31,2**31-1,-17,0,29]) for _ in range(c.out_channels)]
        result=conv2d(c,x,w,b)
        oh,ow,_=c.output_shape()
        ia=0x7f0;wa=0x1fff0;ba=0x40000;oa=0x807f0
        if index==3: oa=0x1ffffc00
        start=len(initial)
        def emit(addr,data):
            assert addr%16==0 and len(data)%16==0
            for off in range(0,len(data),16):
                initial.append(((addr+off)<<128)|int.from_bytes(data[off:off+16],'little'))
        # 无效通道刻意填非零，检查硬件掩码，而非依赖导出端补零。
        xb=bytearray()
        for p in range(c.height*c.width):
            xb.extend((x[p*c.in_channels+k]&255) if k<c.in_channels else 0x55 for k in range(ci))
        wb=bytearray()
        for o in range(co):
            for tap in range(c.kernel*c.kernel):
                wb.extend((w[(o*c.kernel*c.kernel+tap)*c.in_channels+k]&255)
                          if o<c.out_channels and k<c.in_channels else 0x66 for k in range(ci))
        bb=b''.join((b[k] if k<c.out_channels else 0x23456789).to_bytes(4,'little',signed=True) for k in range(co))
        emit(ia,xb);emit(wa,wb);emit(ba,bb)
        expected=[]
        for p in range(oh*ow):
            expected.extend(result[p*c.out_channels+k] if k<c.out_channels else 0 for k in range(co))
        data=b''.join((v&((1<<64)-1)).to_bytes(8,'little') for v in expected)
        emit(oa-16,b'\xa5'*16);emit(oa+len(data),b'\x5a'*16)
        gb=len(golden);golden.extend(int.from_bytes(data[n:n+16],'little') for n in range(0,len(data),16))
        config=c.height|(c.width<<16)|(c.in_channels<<32)|(c.out_channels<<48)|(c.kernel<<64)|(c.stride<<66)|(c.padding<<68)|(int(c.bias_enable)<<70)
        issues=oh*ow*((c.out_channels+3)//4)*((c.in_channels+15)//16)*c.kernel*c.kernel*8
        jobs.append(config|(ia<<96)|(wa<<128)|(ba<<160)|(oa<<192)|(start<<224)|((len(initial)-start)<<256)|(gb<<288)|((len(data)//16)<<320)|(issues<<352))
    for name,values,digits in [('jobs',jobs,96),('initial',initial,40),('golden',golden,32)]:
        (OUT/(name+'.mem')).write_text(''.join(f'{x:0{digits}x}\n' for x in values))
    return len(jobs),len(initial),len(golden)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    jobs,initial,golden=generate()
    run(['iverilog','-g2012','-s','TB_conv2d_ddr_engine','-y',ROOT/'vsrc','-DDDR3_MODEL_SLOTS=8192',
         '-o',OUT/'test.vvp',ROOT/'Iverilog/TB_conv2d_ddr_engine.v',ROOT/'vsrc/ddr3.sv'],'compile.log')
    results={}
    for name,opts in {'normal':[], 'stalled':['+ddr3_random_stalls=1','+ddr3_stall_every=7','+ddr3_stall_cycles=2'],
                      'zero_latency':['+ddr3_read_latency=0','+ddr3_write_latency=0']}.items():
        output=run(['vvp',OUT/'test.vvp',f'+JOBS={jobs}',f'+INITIAL={initial}',f'+GOLDEN={golden}',*opts],name+'.log')
        summaries=[s for s in output.splitlines() if s.startswith('PASS ')]
        if len(summaries)!=1: raise RuntimeError('missing PASS')
        print(name+': '+summaries[0],flush=True);results[name]=summaries[0]
    rtl=[ROOT/('vsrc/'+x+'.v')for x in ('conv2d_ddr_engine','ddr_chunk_client','conv_mac_tile','multiply_adder','requant_int8')]
    run(['verilator','--lint-only','-Wall','--top-module','conv2d_ddr_engine',*rtl],'lint.log')
    run(['verilator','--lint-only','-Wall','--top-module','ddr_cpu_window','-GENABLE_AI=1',
         ROOT/'vsrc/ddr_cpu_window.v',ROOT/'vsrc/ddr_block_transfer.v',*rtl],'lint_window.log')
    run(['verilator','--lint-only','-Wall','-Wno-TIMESCALEMOD','-Wno-SYNCASYNCNET',
         '--top-module','peripheral_bus','-GENABLE_DDR=1','-GENABLE_AI=1',
         ROOT/'vsrc/peripheral_bus.v',ROOT/'vsrc/ddr_cpu_window.v',ROOT/'vsrc/ddr_block_transfer.v',
         ROOT/'vsrc/uart_tx.v',*rtl],'lint_peripheral.log')
    (OUT/'result.json').write_text(json.dumps(dict(results=results,layers=jobs,
        reset_replays=2,invalid=10,readback_words=golden+72,lint=True),indent=2)+'\n')
if __name__=='__main__':main()
