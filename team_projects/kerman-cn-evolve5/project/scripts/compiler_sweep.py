import argparse,concurrent.futures,json,subprocess,sys,os
from pathlib import Path
from regress import PROJECT as P
from build_coremark import build_coremark,DEFAULT_GCC
W=P.parents[1]/'work'
NEW=next((W/'toolchains/gcc15').glob('*/bin/riscv-none-elf-gcc.exe'))
CONFIGS={
 'gcc10_O2':(DEFAULT_GCC,'O2',[]),
 'gcc15_O2':(NEW,'O2',['-fdump-tree-crc-details']),
 'gcc15_O2_nocrc':(NEW,'O2',['-fno-optimize-crc']),
 'gcc15_O3':(NEW,'O3',['-fdump-tree-crc-details']),
 'gcc15_O3_nocrc':(NEW,'O3',['-fno-optimize-crc']),
 'gcc15_O2_lto':(NEW,'O2',['-flto']),
 'gcc15_O3_lto':(NEW,'O3',['-flto']),
 'gcc15_O3_unroll':(NEW,'O3',['-funroll-loops']),
 'gcc15_O3_tune7':(NEW,'O3',['-mtune=sifive-7-series']),
 'gcc15_O3_lto_small':(NEW,'O3',['-flto','--param','max-inline-insns-auto=20','--param','max-inline-insns-single=100']),
 'gcc15_O3_unroll_small':(NEW,'O3',['-funroll-loops','--param','max-unrolled-insns=40','--param','max-average-unrolled-insns=20']),
}
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--stage',choices=['build','simulate'],required=True)
    ap.add_argument('--configs',nargs='+',choices=CONFIGS,default=list(CONFIGS));ap.add_argument('--iterations',type=int,default=2)
    a=ap.parse_args();report=P/'reports/compiler';report.mkdir(parents=True,exist_ok=True)
    def job(name):
        gcc,opt,flags=CONFIGS[name];folder=report/name;folder.mkdir(exist_ok=True)
        record=dict(config=name,compiler=str(gcc),optimization=opt,extra_flags=flags,status='running')
        manifest=folder/'build_status.json' if a.stage=='build' else folder/f'simulation_status_{a.iterations}.json'
        try:
            if a.stage=='build':
                fw=build_coremark(W/f'evolve5_build_{name}',gcc,2048,'native',opt,flags)
                record.update(status='passed',firmware=str(fw[0]),image_bytes=fw[1]['image_bytes'])
            else:
                built=json.loads((folder/'build_status.json').read_text(encoding='utf-8'))
                if built['status']!='passed':return name,dict(status='skipped_build_failed')
                dest=folder/f'run{a.iterations}'
                command=[sys.executable,str(P/'scripts/coremark_regress.py'),'--gcc',str(gcc),'--config','dual','--firmware-dir',built['firmware'],
                         '--profile','--measure-iterations',str(a.iterations),'--build-dir',str(W/f'evolve5_compiler_{name}_{a.iterations}'),'--reports',str(dest)]
                run=subprocess.run(command,capture_output=True,text=True,errors='replace')
                folder.joinpath(f'console{a.iterations}.log').write_text(run.stdout+run.stderr,encoding='utf-8')
                assert run.returncode==0,(run.stdout+run.stderr)[-4000:]
                record.update(status='passed',evidence=str(dest))
        except Exception as exc:record.update(status='failed',error=str(exc))
        manifest.write_text(json.dumps(record,indent=2),encoding='utf-8');print(name,record['status'],flush=True)
        return name,record
    results={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for f in concurrent.futures.as_completed([pool.submit(job,n) for n in a.configs]):
            name,r=f.result();results[name]=r
            (report/f'jobs_{a.stage}_{a.iterations}.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
if __name__=='__main__':main()
