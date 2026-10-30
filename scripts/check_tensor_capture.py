"""One full-frame P2 integration case plus the short source-frame identity test."""
from pathlib import Path
import hashlib,json,subprocess,time
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/tensor-capture'


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    common=[ROOT/'rtl/ddr_native_arbiter.v',ROOT/'rtl/ddr_block_transfer.v',
            ROOT/'rtl/frame_mailbox.v',ROOT/'sim/video/fifo_2_ddr_model.v',
            ROOT/'sim/models/pango_pool_sum_ram.v']
    sources=common+sorted((ROOT/'rtl/video/preprocess').glob('*.v'))
    cases=[]
    for name,extra in [('TB_hdmi_tensor',[]),('TB_frame_protection',[ROOT/'rtl/video/ddr3_write_ctrl_lite.v'])]:
        tb=ROOT/'sim/video'/(name+'.v');binary=OUT/name/'check'
        command=['verilator','--binary','--timing','--assert','-j','4','-Wno-fatal','-Wno-TIMESCALEMOD',
                 '--top-module',name,'--Mdir',str(binary.parent),'-o','check',*map(str,sources+extra+[tb])]
        with (OUT/(name+'_compile.log')).open('w') as log:
            result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        if result.returncode:raise RuntimeError((OUT/(name+'_compile.log')).read_text()[-6000:])
        start=time.monotonic();result=subprocess.run([str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=90)
        output=result.stdout+result.stderr;(OUT/(name+'.log')).write_text(output)
        summary=next((line for line in output.splitlines() if line.startswith('PASS ')),None)
        if result.returncode or not summary:raise RuntimeError(output[-6000:])
        print(summary,flush=True);cases.append(dict(test=name,passed=True,seconds=time.monotonic()-start,summary=summary))
    report=dict(passed=True,stage='P2 CPU-triggered HDMI tensor capture',top_level_connected=True,
                physical_build_verified=False,hardware_tested=False,ai_enabled=False,
                ai_regression_run=False,coremark_run=False,cases=cases,
                sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in
                         sources+[ROOT/'rtl/video/ddr3_write_ctrl_lite.v',ROOT/'sim/video/TB_hdmi_tensor.v',
                         ROOT/'sim/video/TB_frame_protection.v',Path(__file__).resolve()]})
    destination=ROOT/'reports/preprocess/integration.json'
    destination.write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
