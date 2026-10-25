import argparse,hashlib,json,os,shutil,sys
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command
sys.path.insert(0,str(PROJECT/'tests'))
from cache_vectors import generate

def main():
    p=argparse.ArgumentParser(); p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work/cache3_units'); a=p.parse_args()
    report=PROJECT/'reports/cache/units'; report.mkdir(parents=True,exist_ok=True)
    state={'status':'running','cases':[]}; record=report/'result.json'; record.write_text(json.dumps(state))
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
    try:
        configs=[('d_small',0,1,1,2,32768,32768),('i_small',1,1,1,2,32768,32768),
                 ('d_default',0,1,5,2,32768,32768),('i_default',1,1,5,2,32768,32768),
                 ('d_disabled',0,0,5,2,32768,32768),('i_disabled',1,0,5,2,32768,32768),
                 ('d_line8_partial_region',0,1,2,3,32764,32760),('i_line2_partial_region',1,1,2,1,32764,32768)]
        for name,instruction,enable,set_bits,line_word_bits,rom_bytes,ram_bytes in configs:
            cfg=dict(instruction=instruction,enable=enable,set_bits=set_bits,line_word_bits=line_word_bits,rom_bytes=rom_bytes,ram_bytes=ram_bytes)
            build=(a.build_dir/name).resolve(); build.mkdir(parents=True,exist_ok=True)
            out=report/name; out.mkdir(exist_ok=True); facts=generate(build/'vectors.txt',cfg)
            tb=(PROJECT/'sim/tb_cache_unit.sv.in').read_text()
            for key,val in cfg.items(): tb=tb.replace('@'+key.upper()+'@',str(val))
            (build/'tb_cache_unit.sv').write_text(tb,encoding='utf-8')
            sources=sorted((PROJECT/'rtl/cache').glob('*.v'))
            run_command([vb/'xvlog.bat','-sv',*sources,build/'tb_cache_unit.sv'],build,out/'compile.log',env)
            run_command([vb/'xelab.bat','tb_cache_unit','-s','cache_unit'],build,out/'elaborate.log',env)
            output=run_command([vb/'xsim.bat','cache_unit','-runall'],build,out/'simulate.log',env)
            assert 'CACHE_UNIT_PASS' in output,output[-3000:]
            for artifact in ('vectors.txt','tb_cache_unit.sv'): shutil.copy2(build/artifact,out/artifact)
            state['cases'].append({'name':name,**facts,'vectors_sha256':hashlib.sha256((build/'vectors.txt').read_bytes()).hexdigest()})
            print('PASS '+name,flush=True)
        state.update(status='passed',checked_utc=datetime.now(timezone.utc).isoformat(),hardware_tested=False,
                     source_sha256={str(x.relative_to(PROJECT)).replace('\\','/'):hashlib.sha256(x.read_bytes()).hexdigest() for x in (PROJECT/'rtl/cache').glob('*.v')})
        record.write_text(json.dumps(state,indent=2),encoding='utf-8'); print('CACHE_UNIT_REGRESSION_PASS',flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc)); record.write_text(json.dumps(state,indent=2)); raise
if __name__=='__main__': main()
