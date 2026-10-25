import json,os,re
from pathlib import Path
from regress import PROJECT,run_command
def main():
    build=PROJECT.parents[1]/'work/cache3_monitor'; build.mkdir(parents=True,exist_ok=True)
    out=PROJECT/'reports/monitor'; out.mkdir(parents=True,exist_ok=True)
    state={'status':'running'}; manifest=out/'result.json'; manifest.write_text(json.dumps(state))
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    try:
        run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/soc/rv32_monitor.v',PROJECT/'sim/tb_monitor.sv'],build,out/'compile.log',env)
        run_command([vb/'xelab.bat','tb_monitor','-s','monitor'],build,out/'elaborate.log',env)
        text=run_command([vb/'xsim.bat','monitor','-runall'],build,out/'simulate.log',env)
        match=re.search(r'MONITOR_UNIT_PASS cases=(\d+)',text); assert match,text[-4000:]
        state.update(status='passed',cases=int(match[1])); manifest.write_text(json.dumps(state,indent=2)); print('MONITOR_REGRESSION_PASS '+str(state['cases']))
    except Exception as exc:
        state.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(state,indent=2)); raise
if __name__=='__main__': main()
