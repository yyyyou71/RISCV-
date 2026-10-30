"""Short checks for the new shared-DDR and frame ownership logic; AI is disabled."""
from pathlib import Path
import hashlib,json,subprocess,time

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/video-integration'


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    excluded={'memory_core.v','ROM_core.v','multiplier_core.v','acore_fetch_memory.v',
              'multiply_adder.v','multiply_adder_w8a16.v','video_async_fifo.v','MuxKeyInternal.v'}
    sources=[p for p in sorted((ROOT/'rtl').glob('*.v')) if p.name not in excluded]
    sources+=sorted((ROOT/'sim/models').glob('*.v'))
    cases=[]
    tests=[('TB_shared_ddr',[ROOT/'sim/ddr3/ddr3.sv'],[
        '-DDDR3_MODEL_SLOTS=8192','-DDDR3_MODEL_STRICT_READS',
        '-DPROG_FILE="firmware/video_bringup/acore_dual_rom.hex"',
        '-DDATA_FILE="firmware/video_bringup/acore_dual_ram_bytes.hex"']),
        ('TB_frame_mailbox',[],[]),
        ('TB_ddr_region_check',[],[]),
        ('TB_video_timing',[],[]),
        ('TB_frame_protection',[ROOT/'rtl/video/ddr3_write_ctrl_lite.v',ROOT/'sim/video/fifo_2_ddr_model.v'],[])]
    for name,extra,defines in tests:
        binary=OUT/name/'check'
        command=['verilator','--binary','--timing','--assert','-j','4','-Wno-fatal','-Wno-TIMESCALEMOD',
            '--top-module',name,'--Mdir',str(binary.parent),'-o','check',
            *defines,str(ROOT/'sim/video'/(name+'.v')),*map(str,sources+extra)]
        # Unused CPU memory modules still need their macro definitions when parsed.
        if not defines:command[1:1]=['-DPROG_FILE="firmware/video_bringup/acore_dual_rom.hex"',
                                    '-DDATA_FILE="firmware/video_bringup/acore_dual_ram_bytes.hex"']
        with (OUT/(name+'_compile.log')).open('w') as log:
            result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        if result.returncode:raise RuntimeError((OUT/(name+'_compile.log')).read_text()[-6000:])
        for profile,args in ([('normal',[]),('stalled',['+ddr3_random_stalls=1'])] if name=='TB_shared_ddr' else [('normal',[])]):
            started=time.monotonic();result=subprocess.run([str(binary),*args],cwd=ROOT,capture_output=True,text=True,timeout=60)
            text=result.stdout+result.stderr;(OUT/(name+'_'+profile+'.log')).write_text(text)
            passed=result.returncode==0 and 'PASS ' in text
            if not passed:raise RuntimeError(text[-6000:])
            summary=next(l for l in text.splitlines() if l.startswith('PASS '))
            print(name+' '+profile+': '+summary,flush=True)
            cases.append(dict(name=name,profile=profile,passed=True,summary=summary,seconds=time.monotonic()-started))
    report=dict(passed=True,ai_regression_run=False,coremark_run=False,hardware_tested=False,
        cases=cases,verilator=subprocess.check_output(['verilator','--version'],text=True).strip(),
        sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in sources+sorted((ROOT/'sim/video').glob('*.v'))+
                 [ROOT/'rtl/video/ddr3_write_ctrl_lite.v',ROOT/'sim/ddr3/ddr3.sv',Path(__file__).resolve()]})
    dest=ROOT/'reports/video_integration/functional.json';dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
