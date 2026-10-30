"""Short, focused tests of HDMI preprocessing; no AI-network/CoreMark run."""
from pathlib import Path
import hashlib
import json
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/preprocess'


def pixel(mode,x,y):
    if mode==0:return 0,0,0
    if mode==1:return 255,255,255
    if mode==2:return ((x*17+y*29+(x^y)*3)&255,
                       (x*7+y*53+(x*y)%251)&255,
                       (x*11+y*19+((x>>3)^(y*5)))&255)
    if mode==3:return (255 if y%45 in (11,22,33) else 0,
                       255 if y%45==44 else 0,((x//20)*7+y)&255)
    half=int(x%20<10);base=(x//20)%2
    return base+half,base+1+half,base+2+half


def golden(mode):
    # Independent generic floor/ceil window boundaries from main's prepare_image.
    # Use exact rational rounding: q + (2*r>area or half and odd q).
    words=[]
    for oy in range(96):
        y0=oy*1080//96;y1=((oy+1)*1080+95)//96
        for ox in range(96):
            x0=ox*1920//96;x1=((ox+1)*1920+95)//96
            sums=[0,0,0];area=(y1-y0)*(x1-x0)
            if mode in (0,1):sums=[255*area if mode else 0]*3
            else:
                for y in range(y0,y1):
                    for x in range(x0,x1):
                        rgb=pixel(mode,x,y)
                        for channel in range(3):sums[channel]+=rgb[channel]
            values=[]
            for total in sums:
                q,r=divmod(total,area)
                values.append(q+int(2*r>area or (2*r==area and q%2==1)))
            words.extend([values[0]|values[1]<<16|values[2]<<32,0])
    path=OUT/f'golden_{mode}.hex'
    path.write_text(''.join(f'{word:032x}\n' for word in words))
    return path


def checked(command,log,timeout=120):
    started=time.monotonic()
    result=subprocess.run(list(map(str,command)),cwd=ROOT,capture_output=True,text=True,timeout=timeout)
    text=result.stdout+result.stderr;log.write_text(text)
    if result.returncode:raise RuntimeError(text[-5000:])
    return text,time.monotonic()-started


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    sources=sorted((ROOT/'rtl/video/preprocess').glob('*.v'))+[ROOT/'sim/models/pango_pool_sum_ram.v']
    tests=['TB_rgb_mean240','TB_pool_errors','TB_rgb888_pool96']
    cases=[]
    for name in tests:
        binary=OUT/name/'check'
        command=['verilator','--binary','--timing','--assert','-j','4','-Wno-fatal','-Wno-TIMESCALEMOD',
                 '--top-module',name,'--Mdir',binary.parent,'-o','check',*sources,ROOT/'sim/video'/(name+'.v')]
        checked(command,OUT/(name+'_compile.log'))
        profiles=range(5) if name=='TB_rgb888_pool96' else [None]
        for profile in profiles:
            args=[] if profile is None else [f'+pattern={profile}',f'+golden={golden(profile)}']
            text,seconds=checked([binary,*args],OUT/(name+'_'+str(profile)+'.log'),60)
            summary=next((s for s in text.splitlines() if s.startswith('PASS ')),None)
            if not summary:raise RuntimeError(text[-4000:])
            print(summary,flush=True)
            cases.append(dict(test=name,profile=profile,passed=True,summary=summary,seconds=seconds))
    # Four-state run starts with genuinely unknown RAM and reuses dirty storage
    # after malformed/cancelled captures; Verilator alone cannot prove this.
    binary=OUT/'pool_errors.vvp'
    checked(['iverilog','-g2012','-s','TB_pool_errors','-o',binary,*sources,ROOT/'sim/video/TB_pool_errors.v'],OUT/'four_state_compile.log')
    text,seconds=checked(['vvp',binary],OUT/'four_state.log',60)
    if 'PASS ' not in text:raise RuntimeError(text[-4000:])
    summary=next(s for s in text.splitlines() if s.startswith('PASS '))
    print('Icarus four-state: '+summary,flush=True)
    cases.append(dict(test='TB_pool_errors',profile='four_state',passed=True,summary=summary,seconds=seconds))
    report=dict(passed=True,stage='P1 standalone preprocessing core',
        top_level_connected=False,ai_regression_run=False,coremark_run=False,hardware_tested=False,
        input_shape=[1080,1920,3],output_shape=[96,96,16],dtype='little-endian INT16',
        bytes_per_frame=294912,full_frame_patterns=5,compared_rgb_values=5*96*96*3,
        cases=cases,sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sources+[ROOT/'sim/video'/(n+'.v') for n in tests]+[Path(__file__).resolve()]})
    dest=ROOT/'reports/preprocess/functional.json';dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
