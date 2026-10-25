import concurrent.futures,json,subprocess,sys
from pathlib import Path
from regress import PROJECT as P
W=P.parents[1]/'work';root=P/'reports/final_measurements';root.mkdir(parents=True,exist_ok=True)
jobs={'balanced_lto':('fast_both','gcc15_O2_lto'),'tuned_lto':('fast_combo','gcc15_O2_lto'),'tuned_unroll':('fast_combo','gcc15_O3_unroll_small')}
def one(name,item):
 config,compiler=item;fw=W/f'evolve1_build_{compiler}/firmware/coremark'
 args=[sys.executable,str(P/'scripts/coremark_regress.py'),'--config',config,'--firmware-dir',str(fw),'--profile','--measure-iterations','8',
       '--build-dir',str(W/f'evolve5_final_{name}'),'--reports',str(root/name)]
 r=subprocess.run(args,capture_output=True,text=True,errors='replace');(root/(name+'.log')).write_text(r.stdout+r.stderr,encoding='utf-8')
 return name,dict(status='passed' if r.returncode==0 else 'failed',config=config,compiler=compiler)
results={}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(one,n,x) for n,x in jobs.items()]):
  name,row=f.result();results[name]=row;print(name,row['status'],flush=True)
  (root/'jobs.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
assert all(x['status']=='passed' for x in results.values())
