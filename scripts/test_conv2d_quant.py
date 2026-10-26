#!/usr/bin/env python3
"""DDR 卷积→逐通道量化→可选 ReLU→HWC INT8 对拍，使用原 DDR 行为模型。"""
import sys
sys.dont_write_bytecode = True
import json
import random
import subprocess
from pathlib import Path
from conv2d_reference import ConvConfig, conv2d
from quant_reference import quantize_hwc, pack_hwc_int8, pack_quant_params

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/conv2d_quant'


def run(args,log):
    r=subprocess.run([str(x) for x in args],cwd=OUT,capture_output=True,text=True,timeout=120)
    s=r.stdout+r.stderr;(OUT/log).write_text(s)
    if r.returncode: raise RuntimeError(f'{log}\n{s[-5000:]}')
    return s


def generate():
    rng=random.Random(0x8A82026)
    specs=[ConvConfig(3,5,17,5),ConvConfig(3,4,33,19,3,2,1),
           ConvConfig(2,3,1,1,1,2,0,False),ConvConfig(1,1,1,5,1,1,1),
           ConvConfig(3,3,16,16,3,1,0),ConvConfig(2,5,3,17,1,1,0),
           ConvConfig(3,3,65,2,3,1,0,False),ConvConfig(3,5,18,33,1,2,1)]
    for _ in range(8):
        specs.append(ConvConfig(rng.randrange(3,6),rng.randrange(3,7),rng.choice([2,15,16,19,31,32]),
            rng.choice([3,4,6,8,15,18]),rng.choice([1,3]),rng.choice([1,2]),rng.choice([0,1]),bool(rng.randrange(2))))
    initial=[];golden=[];jobs=[]
    for index,c in enumerate(specs):
        ci=(c.in_channels+15)&~15;co=(c.out_channels+3)&~3
        x=[rng.choice([-128,-17,-1,0,1,13,127]) for _ in range(c.height*c.width*c.in_channels)]
        w=[rng.randrange(-7,8) for _ in range(c.out_channels*c.kernel*c.kernel*c.in_channels)]
        b=[rng.choice([-2**31,2**31-1,-17,0,29]) if index==3 else rng.randrange(-99,100) for _ in range(c.out_channels)]
        params=[rng.choice([(1,0),(1,1),(3,7),(17,10),(0x40000000,31),
                            (0x7fffffff,32),(1,63),(1,95),(0,0)]) for _ in range(c.out_channels)]
        relu=bool(index%2)
        result=quantize_hwc(conv2d(c,x,w,b),c.out_channels,params,relu)
        oh,ow,_=c.output_shape()
        ia=0x7f0;wa=0x1fff0;ba=0x40000;qa=0x50000;oa=0x807f0
        if index==3: oa=0x1fffff00
        start=len(initial)
        def emit(addr,data):
            assert addr%16==0 and len(data)%16==0
            initial.extend(((addr+n)<<128)|int.from_bytes(data[n:n+16],'little') for n in range(0,len(data),16))
        emit(ia,pack_hwc_int8(x,c.in_channels,0x55))
        wb=bytearray()
        for o in range(co):
            for tap in range(c.kernel*c.kernel):
                wb.extend((w[(o*c.kernel*c.kernel+tap)*c.in_channels+k]&255)
                          if o<c.out_channels and k<c.in_channels else 0x66 for k in range(ci))
        emit(wa,wb)
        emit(ba,b''.join((b[k] if k<c.out_channels else 0x23456789).to_bytes(4,'little',signed=True) for k in range(co)))
        emit(qa,pack_quant_params(params))
        data=pack_hwc_int8(result,c.out_channels)
        emit(oa-16,b'\xa5'*16);emit(oa+len(data),b'\x5a'*16)
        gb=len(golden);golden.extend(int.from_bytes(data[n:n+16],'little') for n in range(0,len(data),16))
        config=c.height|(c.width<<16)|(c.in_channels<<32)|(c.out_channels<<48)|(c.kernel<<64)|(c.stride<<66)|(c.padding<<68)|(int(c.bias_enable)<<70)
        issues=oh*ow*((c.out_channels+3)//4)*((c.in_channels+15)//16)*c.kernel*c.kernel*8
        jobs.append(config|(ia<<96)|(wa<<128)|(ba<<160)|(oa<<192)|(start<<224)|
                    ((len(initial)-start)<<256)|(gb<<288)|((len(data)//16)<<320)|(issues<<352)|
                    (qa<<384)|((1+2*int(relu))<<416))
    for name,values,digits in [('jobs',jobs,112),('initial',initial,40),('golden',golden,32)]:
        (OUT/(name+'.mem')).write_text(''.join(f'{x:0{digits}x}\n' for x in values))
    return len(jobs),len(initial),len(golden),len(pack_hwc_int8([0]*15*5,5))//16


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    jobs,initial,golden,replay_words=generate()
    run(['iverilog','-g2012','-s','TB_conv2d_ddr_engine','-y',ROOT/'vsrc','-DDDR3_MODEL_SLOTS=8192',
         '-PTB_conv2d_ddr_engine.QUANT_TEST=1','-o',OUT/'test.vvp',
         ROOT/'Iverilog/TB_conv2d_ddr_engine.v',ROOT/'vsrc/ddr3.sv'],'compile.log')
    results={}
    for name,opts in {'normal':[], 'stalled':['+ddr3_random_stalls=1','+ddr3_stall_every=7','+ddr3_stall_cycles=2'],
                      'zero_latency':['+ddr3_read_latency=0','+ddr3_write_latency=0']}.items():
        output=run(['vvp',OUT/'test.vvp',f'+JOBS={jobs}',f'+INITIAL={initial}',f'+GOLDEN={golden}',*opts],name+'.log')
        summaries=[s for s in output.splitlines() if s.startswith('PASS ')]
        if len(summaries)!=1: raise RuntimeError('missing PASS')
        print('quant '+name+': '+summaries[0],flush=True);results[name]=summaries[0]
    (OUT/'result.json').write_text(json.dumps(dict(results=results,layers=jobs,
        reset_replays=2,invalid=20,readback_words=golden+2*replay_words),indent=2)+'\n')


if __name__=='__main__':main()
