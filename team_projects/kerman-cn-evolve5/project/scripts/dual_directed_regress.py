"""Direct second-word prediction and precise instruction fault checks."""
import json,os,shutil
from pathlib import Path
from regress import PROJECT,run_command
report=PROJECT/'reports/dual_directed_v2';report.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
state={'status':'running','configurations':[],'hardware_tested':False}
try:
    for name,param,marker,cases in [('dual_fetch_fault','BYPASS','DUAL_FETCH_FAULT_PASS',48),('dual_prediction','GS','DUAL_PREDICTION_PASS',6)]:
        for value in (0,1):
            key=f'{name}_{param}{value}';build=PROJECT.parents[1]/'work'/key;build.mkdir(exist_ok=True)
            dst=report/key;dst.mkdir(exist_ok=True)
            tb=(PROJECT/f'sim/tb_{name}.sv').read_text().replace(f'parameter {param}=1;',f'parameter {param}={value};')
            (build/'tb.sv').write_text(tb)
            run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sorted((PROJECT/'rtl').glob('*.v')),build/'tb.sv'],build,dst/'compile.log',env)
            run_command([vb/'xelab.bat','tb_'+name,'-s','directed'],build,dst/'elaborate.log',env)
            out=run_command([vb/'xsim.bat','directed','-runall'],build,dst/'simulate.log',env)
            assert marker in out and 'Fatal:' not in out,out[-3000:]
            shutil.copy2(build/'tb.sv',dst/'tb.sv');state['configurations'].append(dict(name=key,cases=cases,status='passed'))
    state['status']='passed';print('DUAL_DIRECTED_PASS',flush=True)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:(report/'result.json').write_text(json.dumps(state,indent=2))
