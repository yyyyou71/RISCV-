import argparse,json,os,sys
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command
sys.path.insert(0,str(PROJECT/'tests'))
from bp_vectors import vectors
def main():
    p=argparse.ArgumentParser(); p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work/cache3_units')
    a=p.parse_args(); build=a.build_dir.resolve(); build.mkdir(parents=True,exist_ok=True)
    reports=PROJECT/'reports/branch/units'; reports.mkdir(parents=True,exist_ok=True)
    state={'status':'running'}; record=reports/'result.json'; record.write_text(json.dumps(state))
    try:
        facts=vectors(build/'bp_vectors.txt'); env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
        run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/rv32_predictor.v',PROJECT/'rtl/rv32_fetch.v',PROJECT/'sim/tb_predictor.sv',PROJECT/'sim/tb_fetch_predict.sv'],build,reports/'compile.log',env)
        for top,marker in [('tb_predictor','PREDICTOR_UNIT_PASS'),('tb_fetch_predict','FETCH_PREDICT_PASS')]:
            run_command([vb/'xelab.bat',top,'-s',top],build,reports/(top+'_elaborate.log'),env)
            text=run_command([vb/'xsim.bat',top,'-runall'],build,reports/(top+'.log'),env)
            if marker not in text: raise RuntimeError(text[-5000:])
        state.update(status='passed',checked_utc=datetime.now(timezone.utc).isoformat(),predictor=facts,
                     fetch_cases=['response_time_prediction','id_stall_metadata','outstanding_request_hold','newer_redirect_priority','fetch_fault_gating','stop_and_resume'])
        record.write_text(json.dumps(state,indent=2)); print('BP_UNIT_REGRESSION_PASS',flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc)); record.write_text(json.dumps(state,indent=2)); raise
if __name__=='__main__': main()
