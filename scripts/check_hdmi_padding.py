"""Focused HDMI width checks; one white 1919x1080 frame, no AI/network rerun."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def main():
    out=ROOT/'build/hdmi-padding'
    out.mkdir(parents=True,exist_ok=True)
    # 20-wide pooling bins: the last has 19 white pixels and one black pixel.
    # RNE(255*19/20)=242. All other bins remain white (255).
    golden=out/'white_1919.hex'
    words=[]
    for y in range(96):
        for x in range(96):
            v=242 if x==95 else 255
            words.extend([v|(v<<16)|(v<<32),0])
    golden.write_text(''.join(f'{word:032x}\n' for word in words))
    common=[ROOT/'rtl/video/hdmi_line_pad.v']
    tests=[('TB_hdmi_line_pad',common,[],[]),
           ('TB_video_timing',[ROOT/'rtl/video_timing_monitor.v'],[],[]),
           ('TB_rgb888_pool96',common+list((ROOT/'rtl/video/preprocess').glob('*.v'))+
             [ROOT/'sim/models/pango_pool_sum_ram.v'],['-GPAD_INPUT=1'],
             ['+pattern=1','+source_width=1919','+golden='+str(golden)])]
    cases=[]
    for top,sources,options,args in tests:
        binary=out/top/'check'
        command=['verilator','--binary','--timing','--assert','-j','4','-Wno-fatal',
                 '-Wno-TIMESCALEMOD','--top-module',top,'--Mdir',str(binary.parent),
                 '-o','check',*options,str(ROOT/'sim/video'/(top+'.v')),*map(str,sources)]
        with (out/(top+'_compile.log')).open('w') as log:
            result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        if result.returncode:raise RuntimeError((out/(top+'_compile.log')).read_text()[-5000:])
        result=subprocess.run([str(binary),*args],cwd=ROOT,capture_output=True,text=True,timeout=60)
        text=result.stdout+result.stderr
        (out/(top+'_run.log')).write_text(text)
        if result.returncode or 'PASS ' not in text:raise RuntimeError(text[-5000:])
        summary=next(line for line in text.splitlines() if line.startswith('PASS '))
        cases.append(dict(name=top,passed=True,summary=summary))
        print(summary,flush=True)
    report=dict(passed=True,scope=__doc__,cases=cases,hardware_tested=False,
        sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in {p for _,sources,_,_ in tests for p in sources}})
    (ROOT/'reports/video_integration/hdmi_padding_checks.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
