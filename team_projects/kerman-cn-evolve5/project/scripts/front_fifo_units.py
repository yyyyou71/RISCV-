import json,os,shutil
from pathlib import Path
from regress import PROJECT,run_command
env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
report=PROJECT/'reports/front_fifo_units';report.mkdir(parents=True,exist_ok=True);results=[]
for depth in (1,2,4,8):
    for bypass in (0,1):
        name=f'd{depth}_b{bypass}';build=PROJECT.parents[1]/'work'/('evolve5_fifo_'+name);build.mkdir(exist_ok=True)
        tb=(PROJECT/'sim/tb_front_fifo.sv').read_text().replace('parameter D=2,BYPASS=0;',f'parameter D={depth},BYPASS={bypass};')
        (build/'tb.sv').write_text(tb)
        run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/rv32_predictor.v',PROJECT/'rtl/rv32_fetch.v',build/'tb.sv'],build,build/'compile.log',env)
        run_command([vb/'xelab.bat','tb_front_fifo','-s','fifo'],build,build/'elaborate.log',env)
        out=run_command([vb/'xsim.bat','fifo','-runall'],build,build/'simulate.log',env)
        assert 'FRONT_FIFO_PASS' in out,out[-3000:]
        dst=report/name;dst.mkdir(exist_ok=True)
        for f in ('tb.sv','compile.log','elaborate.log','simulate.log'):shutil.copy2(build/f,dst/f)
        results.append({'depth':depth,'bypass':bypass,'cycles':6000,'status':'passed'})
        (report/'result.json').write_text(json.dumps({'status':'running','configurations':results},indent=2))
(report/'result.json').write_text(json.dumps({'status':'passed','configurations':results},indent=2))
print('FRONT_FIFO_ALL_PASS',flush=True)
