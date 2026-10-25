"""Copy immutable evidence from the measured phases, excluding tool binaries."""
import json,shutil
from pathlib import Path
from regress import PROJECT as P
items={
 'rv32im_evolve1':['reports/compiler','reports/compiler_initial','reports/compiler_measurements.json','reports/frozen_profile','docs/编译对照阶段结果.md'],
 'rv32im_evolve2':['reports/branch_cm8','reports/branch_stage_summary.json','reports/branch_directed'],
 'rv32im_evolve3':['reports/shared_cm8_v3','reports/lsu_directed'],
 'rv32im_evolve4':['reports/store_cm8','reports/mul_cm8','reports/both_cm8','reports/final_measurements','reports/predictor_sweep','reports/pds','reports/machine/fast_both','reports/machine/fast_both_v2','reports/machine/fast_both_v3'],
}
for phase,paths in items.items():
 for relative in paths:
  source=P.parent/phase/relative;target=P/'reference/phases'/phase/relative
  if not source.exists():continue
  target.parent.mkdir(parents=True,exist_ok=True)
  if source.is_dir():shutil.copytree(source,target,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
  else:shutil.copy2(source,target)
provenance=P.parents[1]/'work/toolchains/gcc15_install.json'
shutil.copy2(provenance,P/'reference/gcc15_install.json')
folder=P/'reference/frozen_evolve1_lto';folder.mkdir(exist_ok=True)
for f in (P.parents[1]/'work/evolve1_build_gcc15_O2_lto/firmware/coremark').iterdir():
 if f.is_file() and f.suffix!='.o':shutil.copy2(f,folder/f.name)
print('PHASE_EVIDENCE_ARCHIVED')
