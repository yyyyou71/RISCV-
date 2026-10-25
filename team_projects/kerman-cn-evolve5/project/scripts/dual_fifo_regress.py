import json,os,shutil
from pathlib import Path
from regress import PROJECT,run_command
report=PROJECT/'reports/dual_fifo_v2';report.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin');records=[]
state={'status':'running','configurations':records,'hardware_tested':False}
try:
    for depth in (2,4,8):
        for bypass in (0,1):
            for dual,wide in ((0,1),(1,0),(1,1)):
                name=f'd{depth}_b{bypass}_i{dual}_w{wide}';build=PROJECT.parents[1]/'work'/('evolve5_fifo_'+name);build.mkdir(exist_ok=True)
                dst=report/name;dst.mkdir(exist_ok=True)
                tb=(PROJECT/'sim/tb_dual_fifo.sv').read_text().replace('parameter D=4,BYPASS=1,DUAL=1,WIDE=1;',f'parameter D={depth},BYPASS={bypass},DUAL={dual},WIDE={wide};')
                (build/'tb.sv').write_text(tb)
                run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/rv32_predictor.v',PROJECT/'rtl/rv32_fetch.v',build/'tb.sv'],build,dst/'compile.log',env)
                run_command([vb/'xelab.bat','tb_dual_fifo','-s','fifo'],build,dst/'elaborate.log',env)
                out=run_command([vb/'xsim.bat','fifo','-runall'],build,dst/'simulate.log',env)
                assert 'DUAL_FIFO_PASS' in out,out[-2500:]
                shutil.copy2(build/'tb.sv',dst/'tb.sv');records.append(dict(name=name,cycles=6000,status='passed'))
                (report/'result.json').write_text(json.dumps(state,indent=2))
    state['status']='passed';print('DUAL_FIFO_ALL_PASS',flush=True)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:(report/'result.json').write_text(json.dumps(state,indent=2))
