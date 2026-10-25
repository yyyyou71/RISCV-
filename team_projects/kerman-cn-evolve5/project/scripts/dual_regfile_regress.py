import json,os,shutil
from pathlib import Path
from regress import PROJECT,run_command
build=PROJECT.parents[1]/'work/dual1_regfile';build.mkdir(exist_ok=True)
report=PROJECT/'reports/dual_regfile';report.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
state={'status':'running','hardware_tested':False}
try:
    run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/rv32_regfile.v',PROJECT/'sim/tb_dual_regfile.sv'],build,report/'compile.log',env)
    run_command([vb/'xelab.bat','tb_dual_regfile','-s','regfile'],build,report/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','regfile','-runall'],build,report/'simulate.log',env)
    assert 'DUAL_REGFILE_PASS vectors=6000' in out,out[-2000:]
    state.update(status='passed',vectors=6000)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:(report/'result.json').write_text(json.dumps(state,indent=2))
