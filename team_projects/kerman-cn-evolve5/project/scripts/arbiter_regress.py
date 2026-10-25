import json,os
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command
def main():
    build=PROJECT.parents[1]/'work/cache3_arbiter'; build.mkdir(parents=True,exist_ok=True)
    out=PROJECT/'reports/backend/arbiter'; out.mkdir(parents=True,exist_ok=True)
    manifest=out/'result.json'; state={'status':'running'}; manifest.write_text(json.dumps(state))
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    try:
        run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/cache/rv32_burst_arbiter.v',PROJECT/'sim/tb_burst_arbiter.sv'],build,out/'compile.log',env)
        run_command([vb/'xelab.bat','tb_burst_arbiter','-s','arbiter'],build,out/'elaborate.log',env)
        result=run_command([vb/'xsim.bat','arbiter','-runall'],build,out/'simulate.log',env)
        assert 'BURST_ARBITER_PASS' in result,result[-4000:]
        state.update(status='passed',checked_utc=datetime.now(timezone.utc).isoformat(),commands_per_master=48,
                     checks=['late requester while command stalled','round-robin contention','response ownership/length/error','consumer backpressure','reset during stalled command/response'])
        manifest.write_text(json.dumps(state,indent=2)); print('ARBITER_REGRESSION_PASS')
    except Exception as exc:
        state.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(state,indent=2)); raise
if __name__=='__main__': main()
