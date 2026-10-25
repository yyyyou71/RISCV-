"""Two isolated physical implementations under unchanged clock constraints."""
import concurrent.futures,json,subprocess,sys
from pathlib import Path
from regress import PROJECT as P
W=P.parents[1]/'work';root=P/'reports/pds';fw=W/'evolve1_build_gcc15_O2_lto/firmware/coremark'
jobs={'speed_s6':(6,False),'speed_cluster_s1':(1,True)}
def one(label,item):
 seed,cluster=item
 args=[sys.executable,str(P/'scripts/dual_pds.py'),'--config','mul_pair_combo','--firmware-dir',str(fw),'--artifact-label',label,
       '--seed',str(seed),'--hold-iterations','20','--hold-margin-ps','200','--srb-hold-margin-ps','1800',
       '--build-dir',str(W/('evolve5_pds_'+label)),'--reports',str(root/label)]
 if cluster:args+=['--cluster']
 r=subprocess.run(args,capture_output=True,text=True,errors='replace')
 (root/(label+'.console.log')).write_text(r.stdout+r.stderr,encoding='utf-8')
 return label,dict(exit_code=r.returncode,status='passed' if r.returncode==0 else 'failed')
results={}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for f in concurrent.futures.as_completed([pool.submit(one,n,v) for n,v in jobs.items()]):
  name,row=f.result();results[name]=row;print(name,row['status'],flush=True)
  (root/'speed_retry_jobs.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
