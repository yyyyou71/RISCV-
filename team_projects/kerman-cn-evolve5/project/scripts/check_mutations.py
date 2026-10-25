"""Check that representative RTL bugs are rejected; never edit production RTL."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from regress import PROJECT, run_command


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work'/'cache3_cpu')
    a = p.parse_args()
    build = a.build_dir.resolve()
    rows = list(csv.DictReader((PROJECT/'reports'/'cases.csv').open(encoding='utf-8')))
    drained = next(r['name'] for r in rows if int(r['drained_fetch']) > 0)
    manifests = {line.split()[0]:line for line in (build/'manifest.txt').read_text().splitlines()}
    mutations = [
        ('arithmetic_shift','rv32_alu.v','result = $signed(a) >>> b[4:0];','result = a >> b[4:0];','upstream_sra__i0d0'),
        ('held_wb_operand','rv32_core.v','x_r1 <= operand1;\n                    x_r2 <= operand2;','x_r1 <= x_r1;\n                    x_r2 <= x_r2;','held_wb_operand__i0d3'),
        ('younger_store_after_trap','rv32_core.v','&& !halted && !halting && !rst;','&& !halted && !rst;','older_store_before_trap__i0d0'),
        ('stale_fetch_response','rv32_fetch.v','if (!killed && !redirect && !stop)','if (!redirect && !stop)',drained),
    ]
    baseline_hash = {x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in (PROJECT/'rtl').glob('*') if x.is_file()}
    report = {'status':'running','started_utc':datetime.now(timezone.utc).isoformat(),'mutations':[],
              'production_rtl_sha256':baseline_hash}
    report_path = PROJECT/'reports'/'mutation_checks.json'
    report_path.write_text(json.dumps(report,indent=2),encoding='utf-8')
    env = os.environ.copy(); env['PROCESSOR_ARCHITECTURE'] = 'AMD64'
    vb = a.vivado/'bin'
    for name,filename,old,new,case in mutations:
        target = build/'mutations'/name
        (target/'cases').mkdir(parents=True,exist_ok=True)
        source = (PROJECT/'rtl'/filename).read_text(encoding='utf-8')
        if source.count(old) != 1: raise RuntimeError(f'Mutation anchor is ambiguous: {name}')
        mutated = target/filename
        mutated.write_text(source.replace(old,new),encoding='utf-8')
        line = manifests[case]
        for rel in line.split()[1:3]: shutil.copy2(build/rel,target/rel)
        (target/'manifest.txt').write_text(line+'\n',encoding='ascii')
        (target/'xsim.args').write_text('--testplusarg MANIFEST=manifest.txt\n--testplusarg RESULTS=results.csv\n--testplusarg TRACE=retire.log\n',encoding='ascii')
        sources = [mutated if f.name == filename else f for f in sorted((PROJECT/'rtl').glob('*.v'))]
        run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sources,PROJECT/'sim'/'tb_core.sv'],target,target/'compile.log',env)
        run_command([vb/'xelab.bat','tb_core','-s','mutant','-mt','4'],target,target/'elaborate.log',env)
        result = subprocess.run([str(vb/'xsim.bat'),'mutant','-runall','-f','xsim.args'],cwd=target,env=env,
                                capture_output=True,text=True,errors='replace',timeout=120)
        output = result.stdout+result.stderr
        (target/'simulate.log').write_text(output,encoding='utf-8')
        failures = [line for line in output.splitlines() if 'Fatal:' in line or line.startswith('DIFF ') or 'Error:' in line]
        detected = any(token in output for token in ('Architectural differential mismatch','Extra/missing data transaction','Memory side-effect mismatch'))
        if not detected or 'REGRESSION_PASS' in output:
            raise RuntimeError(f'Mutation was not rejected by the functional checker: {name}\n{output[-4000:]}')
        item = {'name':name,'file':filename,'case':case,'detected':True,'diagnostics':failures,
                'mutated_sha256':hashlib.sha256(mutated.read_bytes()).hexdigest()}
        report['mutations'].append(item)
        shutil.copy2(target/'simulate.log',PROJECT/'reports'/('mutation_'+name+'.log'))
        print(f'EXPECTED_FAILURE {name}: {case}',flush=True)
    after = {x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in (PROJECT/'rtl').glob('*') if x.is_file()}
    if baseline_hash != after: raise RuntimeError('Production RTL unexpectedly changed')
    report.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),production_rtl_unchanged=True)
    report_path.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('MUTATION_CHECKS_PASS 4/4; production RTL unchanged',flush=True)


if __name__ == '__main__': main()
