"""Rebuild and execute the board-independent regression with Vivado XSim."""
import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from front_configs import CONFIGS,parameters
from dual_testbench import dualize_core_tb

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT/'tests'))
from generate import generate
from unit_vectors import make_vectors


def run_command(args, cwd, log, env, timeout=600):
    print('RUN '+Path(str(args[0])).name,flush=True)
    result = subprocess.run([str(x) for x in args],cwd=cwd,env=env,
                            capture_output=True,text=True,errors='replace',timeout=timeout)
    text = result.stdout + result.stderr
    log.write_text(text,encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {args}\n{text[-8000:]}')
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--suite',choices=['smoke','all'],default='all')
    parser.add_argument('--seeds',type=int,default=24)
    parser.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    parser.add_argument('--gcc',type=Path,default=Path(r'D:\riscv\riscv64-unknown-elf-toolchain-10.2.0-2020.12.8-x86_64-w64-mingw32\bin\riscv64-unknown-elf-gcc.exe'))
    parser.add_argument('--build-dir',type=Path)
    parser.add_argument('--config',choices=CONFIGS,default='baseline')
    parser.add_argument('--reuse-vectors',action='store_true')
    args = parser.parse_args()
    build = (args.build_dir or PROJECT.parents[1]/'work'/'evolve5_compat').resolve()
    build.mkdir(parents=True,exist_ok=True)
    reports = PROJECT/'reports/rv32i'/args.config
    reports.mkdir(parents=True,exist_ok=True)
    state = {'status':'running','suite':args.suite,'started_utc':datetime.now(timezone.utc).isoformat()}
    latest = reports/'latest_run.json'
    latest.write_text(json.dumps(state,indent=2),encoding='utf-8')
    start = time.monotonic()
    try:
        env = os.environ.copy()
        env['PROCESSOR_ARCHITECTURE'] = 'AMD64'
        if args.reuse_vectors:
            info=json.loads((build/'generation.json').read_text(encoding='utf-8'))
            assert info['suite']==args.suite and info['random_seeds']==args.seeds
        else:info = generate(PROJECT,build,args.gcc,args.suite,args.seeds)
        print(f"Generated {len(info['programs'])} programs / {info['simulation_cases']} timing cases",flush=True)
        vb = args.vivado/'bin'
        sources = [PROJECT/'rtl'/n for n in ('rv32_alu.v','rv32_decode.v','rv32_regfile.v','rv32_predictor.v','rv32_fetch.v','rv32_csr.v','rv32_core.v')]
        tb=(PROJECT/'sim/tb_core.sv').read_text().replace(".RESET_MTVEC(32'he000)",".RESET_MTVEC(32'he000),"+parameters(CONFIGS[args.config]))
        tb=dualize_core_tb(tb,CONFIGS[args.config]['wide_fetch'])
        (build/'tb_core.sv').write_text(tb)
        alu_vectors = make_vectors(build/'alu_vectors.txt')
        run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sources,build/'tb_core.sv',PROJECT/'sim'/'tb_modules.sv'],build,build/'compile.log',env)
        run_command([vb/'xelab.bat','tb_modules','-s','rv32_modules','-mt','4'],build,build/'modules_elaborate.log',env)
        module_output = run_command([vb/'xsim.bat','rv32_modules','-runall'],build,build/'modules.log',env)
        if 'MODULES_PASS' not in module_output:
            raise RuntimeError('Module tests did not pass.\n'+module_output[-4000:])
        run_command([vb/'xelab.bat','tb_core','-s','rv32_regression','-debug','typical','-mt','4'],build,build/'elaborate.log',env)
        # Keep '=' arguments out of AMD's Windows .bat argument re-parser.
        (build/'xsim.args').write_text('--testplusarg MANIFEST=manifest.txt\n--testplusarg RESULTS=results.csv\n--testplusarg TRACE=retire.log\n',encoding='ascii')
        output = run_command([vb/'xsim.bat','rv32_regression','-runall','-f','xsim.args'],build,build/'simulate.log',env,timeout=900)
        if 'REGRESSION_PASS' not in output:
            raise RuntimeError('Simulator did not reach the regression pass marker.\n'+output[-6000:])
        rows = list(csv.DictReader((build/'results.csv').open(encoding='utf-8')))
        expected_names = [x.split()[0] for x in (build/'manifest.txt').read_text().splitlines()]
        if [r['name'] for r in rows] != expected_names:
            raise RuntimeError('Missing, reordered or duplicated simulation cases')
        totals = Counter()
        for row in rows:
            totals.update({k:int(v) for k,v in row.items() if k != 'name'})
        if args.suite == 'all':
            for key in ('load_stalls','data_waits','fetch_waits','redirects','mem_forward','wb_forward','held_wb','drained_fetch','full_pipeline'):
                if totals[key] == 0: raise RuntimeError(f'Unexercised hardware coverage: {key}')
        manifest_hashes = {}
        for folder in ('rtl','sim','tests','scripts','third_party'):
            for path in sorted((PROJECT/folder).rglob('*')):
                if path.is_file() and '__pycache__' not in path.parts:
                    manifest_hashes[path.relative_to(PROJECT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        state.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),
                     elapsed_seconds=round(time.monotonic()-start,2),python=sys.version,
                     gcc=run_command([args.gcc,'--version'],build,build/'gcc_version.log',env).splitlines()[0],
                     simulator=str(args.vivado),build_directory=str(build),cases=len(rows),
                     totals=dict(totals),generation=info,source_sha256=manifest_hashes,alu_vectors=alu_vectors,
                     limitations=['No FPGA synthesis/place-and-route/board validation in this stage',
                                  'Project ISS is not Spike or an official certification oracle',
                                  'Upstream RV32UI bodies use a project EEI harness; no official ISA certification claimed',
                                  'This RV32I regression checks through the first trap; CSR/interrupt/return tests are in reports/machine',
                                  'Zifencei and misaligned-access emulation are not implemented'])
        shutil.copy2(build/'results.csv',reports/'cases.csv')
        shutil.copy2(build/'compile.log',reports/'compile.log')
        shutil.copy2(build/'elaborate.log',reports/'elaborate.log')
        shutil.copy2(build/'simulate.log',reports/'simulate.log')
        shutil.copy2(build/'modules.log',reports/'modules.log')
        latest.write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
        print(f"PASS {len(rows)} cases, {totals['packets']} differential packets, {info['rv32i_instruction_kinds']}/40 RV32I instruction kinds",flush=True)
        print(f'Results: {reports}',flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc),elapsed_seconds=round(time.monotonic()-start,2))
        latest.write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
        raise


if __name__ == '__main__':
    main()
