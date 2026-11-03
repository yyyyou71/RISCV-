"""Four-state CPU/window tests across clock ratios and delayed DDR responses.

Uses the real runtime/commit code in the existing directed CPU probe. No SPI,
physical PHY, complete upload, or routed-delay coverage is claimed here.
"""
from pathlib import Path
import json,subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/commit-clock-stress';OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(['python3','scripts/check_model_commit_cpu.py'],cwd=ROOT,check=True,timeout=120,
               stdout=(OUT/'prepare.log').open('w'),stderr=subprocess.STDOUT)
cases=[]
profiles={
 'random_ddr':['+ddr3_random_stalls=1','+ddr3_seed=93827'],
 'slow_ddr':['+ddr3_read_latency=39','+ddr3_write_latency=27','+ddr3_stall_every=13','+ddr3_stall_cycles=7'],
 'fast_cpu_slow_ddr':['+cpu_half_ns=7','+ddr3_core_period_ns=17.13','+ddr3_random_stalls=1','+ddr3_seed=12345'],
 'phase_changed':['+cpu_half_ns=23','+ddr3_core_period_ns=8.113','+ddr3_read_latency=0','+ddr3_write_latency=0'],
}
for dual in [0,1]:
 for name,args in profiles.items():
  p=subprocess.run(['vvp',str(ROOT/f'build/model-commit-probe/probe-{dual}.vvp'),
                    '+global_timeout_ns=20000000',*args],cwd=ROOT,capture_output=True,text=True,timeout=90)
  (OUT/f'{dual}-{name}.log').write_text(p.stdout+p.stderr)
  passed=p.returncode==0 and 'PASS cpu_mmio' in p.stdout
  cases.append(dict(dual=dual,profile=name,passed=passed,args=args))
  print(f'CPU dual={dual} {name}: '+('PASS' if passed else 'FAIL'),flush=True)
  if not passed:raise RuntimeError(p.stdout[-3000:]+p.stderr[-1000:])
(ROOT/'reports/spi_image/commit_clock_stress.json').write_text(json.dumps(dict(passed=True,
 scope='four-state real CPU/runtime/window and behavioral DDR, directed header retention/commit',
 full_upload_verified=False,physical_vendor_model=False,routed_delays_simulated=False,cases=cases),indent=2)+'\n')
