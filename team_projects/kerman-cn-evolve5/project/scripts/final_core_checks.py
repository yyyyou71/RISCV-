"""Run the final source revision against independent retirement oracles."""
import concurrent.futures,json,subprocess,sys
from pathlib import Path
from regress import PROJECT as P
W=P.parents[1]/'work';root=P/'reports/final_core_checks';root.mkdir(parents=True,exist_ok=True)
jobs={
 'rv32i':['regress.py','--suite','all','--config','mul_pair_combo','--build-dir',str(W/'evolve5_i_fast'),'--reuse-vectors'],
 'rv32im':['m_core_regress.py','--config','mul_pair_combo'],
 'lsu':['lsu_pair_regress.py','--config','mul_pair_combo'],
}
def one(name,args):
 r=subprocess.run([sys.executable,str(P/'scripts'/args[0]),*args[1:]],capture_output=True,text=True,errors='replace')
 (root/(name+'.log')).write_text(r.stdout+r.stderr,encoding='utf-8')
 return name,dict(status='passed' if r.returncode==0 else 'failed',exit_code=r.returncode)
result={}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for future in concurrent.futures.as_completed([pool.submit(one,n,a) for n,a in jobs.items()]):
  name,row=future.result();result[name]=row;print(name,row['status'],flush=True)
  (root/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
assert all(x['status']=='passed' for x in result.values())
