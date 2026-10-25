import argparse,csv,hashlib,json,os,shutil
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command

def main():
    p=argparse.ArgumentParser(); p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado')); a=p.parse_args()
    report=PROJECT/'reports/backend/memory'; report.mkdir(parents=True,exist_ok=True)
    state={'status':'running','configurations':[]}; manifest=report/'result.json'; manifest.write_text(json.dumps(state))
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
    try:
        for wait,gap in ((0,0),(4,0),(8,0),(8,2)):
            name=f'w{wait}_g{gap}'; build=PROJECT.parents[1]/'work/cache3_backend'/name; build.mkdir(parents=True,exist_ok=True)
            out=report/name; out.mkdir(exist_ok=True)
            (build/'unit_rom.hex').write_text(''.join(f'{(n*4)^0xa5c35a7e:08x}\n' for n in range(8192)))
            tb=(PROJECT/'sim/tb_burst_backend.sv.in').read_text().replace('@FIRST_WAIT@',str(wait)).replace('@BEAT_GAP@',str(gap))
            (build/'tb_burst_backend.sv').write_text(tb)
            run_command([vb/'xvlog.bat','-sv',*sorted((PROJECT/'rtl/soc').glob('*.v')),*sorted((PROJECT/'rtl/cache').glob('*.v')),build/'tb_burst_backend.sv'],build,out/'compile.log',env)
            run_command([vb/'xelab.bat','tb_burst_backend','-s','backend'],build,out/'elaborate.log',env)
            output=run_command([vb/'xsim.bat','backend','-runall'],build,out/'simulate.log',env)
            assert 'BURST_BACKEND_PASS' in output,output[-4000:]
            rows=list(csv.DictReader((build/'transport_metrics.csv').open()))
            for n in ('transport_metrics.csv','tb_burst_backend.sv'): shutil.copy2(build/n,out/n)
            state['configurations'].append({'name':name,'first_wait':wait,'beat_gap':gap,'measurements':rows}); print('BACKEND_PASS '+name,flush=True)
        state.update(status='passed',checked_utc=datetime.now(timezone.utc).isoformat(),hardware_tested=False)
        manifest.write_text(json.dumps(state,indent=2)); print('BACKEND_REGRESSION_PASS')
    except Exception as exc:
        state.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(state,indent=2)); raise
if __name__=='__main__': main()
