"""Run the final release configuration CPU, machine and fetch-fault checks."""
import argparse,concurrent.futures,json,subprocess,sys
from regress import PROJECT
p=argparse.ArgumentParser();p.add_argument('--configs',nargs='+',default=['lean32','combo256']);a=p.parse_args()
report=PROJECT/'reports/final_regression';report.mkdir(parents=True,exist_ok=True)
def one(config):
    jobs=[('m_core_regress.py',['--config',config]),
          ('machine_regress.py',['--config',config,'--m-enable','1','--build-dir',str(PROJECT.parents[1]/'work'/('evolve5_machine_'+config)),
                                '--reports',str(PROJECT/'reports/machine'/config)]),
          ('m_fetch_fault_regress.py',['--config',config])]
    records=[]
    for script,args in jobs:
        r=subprocess.run([sys.executable,str(PROJECT/'scripts'/script),*args],capture_output=True,text=True,errors='replace')
        (report/(config+'_'+script+'.log')).write_text(r.stdout+r.stderr,encoding='utf-8')
        records.append({'script':script,'exit_code':r.returncode})
        print(config+' '+script+' '+str(r.returncode),flush=True)
        if r.returncode:break
    return config,records
results={}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    for future in concurrent.futures.as_completed([pool.submit(one,c) for c in a.configs]):
        config,records=future.result();results[config]=records
        (report/'jobs.json').write_text(json.dumps(results,indent=2))
assert all(len(rows)==3 and all(row['exit_code']==0 for row in rows) for rows in results.values())
