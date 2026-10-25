"""Bounded concurrent XSim jobs, each with its own work and evidence directory."""
import argparse,concurrent.futures,json,subprocess,sys
from pathlib import Path
from regress import PROJECT
from front_configs import CONFIGS
def main():
    p=argparse.ArgumentParser(); p.add_argument('--configs',nargs='+',choices=CONFIGS,default=list(CONFIGS))
    p.add_argument('--round',default='sweep1'); p.add_argument('--iterations',type=int,default=2)
    p.add_argument('--firmware-ref',choices=('front1','dual1'),default='front1')
    p.add_argument('--firmware-dir',type=Path)
    p.add_argument('--workers',type=int,default=3); a=p.parse_args()
    root=PROJECT/'reports'/a.round; root.mkdir(parents=True,exist_ok=True)
    results={}
    def one(name):
        build=PROJECT.parents[1]/'work'/f'evolve5_{a.round}_{name}'
        cmd=[sys.executable,str(PROJECT/'scripts/coremark_regress.py'),'--config',name,'--frozen','--firmware-ref',a.firmware_ref,
             '--measure-iterations',str(a.iterations),'--build-dir',str(build),'--reports',str(root/name)]
        if a.firmware_dir:cmd+=['--firmware-dir',str(a.firmware_dir)]
        r=subprocess.run(cmd,capture_output=True,text=True,errors='replace')
        (root/(name+'.console.log')).write_text(r.stdout+r.stderr,encoding='utf-8')
        return name,{'exit_code':r.returncode,'passed':r.returncode==0}
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.workers) as pool:
        for future in concurrent.futures.as_completed([pool.submit(one,n) for n in a.configs]):
            name,record=future.result(); results[name]=record
            (root/'jobs.json').write_text(json.dumps(results,indent=2))
            print(name+' '+('PASS' if record['passed'] else 'FAIL'),flush=True)
    assert all(r['passed'] for r in results.values()),results
if __name__=='__main__': main()
