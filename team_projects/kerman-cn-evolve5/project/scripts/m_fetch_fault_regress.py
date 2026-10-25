import argparse,json,os,shutil
from pathlib import Path
from regress import PROJECT,run_command
from front_configs import CONFIGS,parameters
p=argparse.ArgumentParser(); p.add_argument('--label',default='fixed');p.add_argument('--config',choices=CONFIGS,default='baseline'); a=p.parse_args()
a.label=a.config+'_'+a.label
build=PROJECT.parents[1]/'work'/('evolve5_fetch_fault_'+a.label); build.mkdir(exist_ok=True)
report=PROJECT/'reports/fetch_fault'/a.label; report.mkdir(parents=True,exist_ok=True)
env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'
vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin'); state={'status':'running','hardware_tested':False}
try:
    tb=(PROJECT/'sim/tb_m_fetch_fault.sv').read_text().replace('.M_ENABLE(1)', '.M_ENABLE(1),'+parameters(CONFIGS[a.config]))
    (build/'tb.sv').write_text(tb)
    run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sorted((PROJECT/'rtl').glob('*.v')),build/'tb.sv'],build,build/'compile.log',env)
    run_command([vb/'xelab.bat','tb_m_fetch_fault','-s','fault','-mt','4'],build,build/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','fault','-runall'],build,build/'simulate.log',env)
    assert 'M_FETCH_FAULT_PASS cases=8' in out
    state.update(status='passed',cases=8)
except Exception as exc: state.update(status='failed',error=str(exc)); raise
finally:
    for f in build.glob('*.log'): shutil.copy2(f,report/f.name)
    (report/'result.json').write_text(json.dumps(state,indent=2))
