"""Sign off measured IPC, source binding, mapped hardware and protected releases."""
import argparse,csv,hashlib,json,re,shutil,subprocess,sys
from pathlib import Path
from regress import PROJECT as P
from parse_coremark import parse_text
from verify_dual_log import check_dual_boot
from platform_identity import check_runs
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def measure(folder):
 r=read(folder/'simulation.json');assert r['status']=='passed',folder
 text=(folder/'coremark_uart.txt').read_text(encoding='utf-8')
 parsed=parse_text(text,'simulation')
 identity=check_runs(text,r['prepared'],r['prepared']['firmware']['build_id'],r['prepared']['firmware']['printed_flags'])
 assert identity['identity_checks']==[True]*4 and identity['flags_checks']==[True]*4
 raw_bus=[{k:int(v) for k,v in x.items()} for x in csv.DictReader((folder/'bus_metrics.csv').open())]
 raw_dual=[{k:int(v) for k,v in x.items()} for x in csv.DictReader((folder/'dual_metrics.csv').open())]
 assert raw_bus==r['bus_metrics'] and raw_dual==r['dual_metrics']
 timer=list(csv.DictReader((folder/'timer_intervals.csv').open()))
 assert len(parsed['runs'])==len(timer)==len(r['bus_metrics'])==4
 rows=[]
 for n,u in enumerate(parsed['runs']):
  b=r['bus_metrics'][n];d=r['dual_metrics'][n]
  assert u['standard_crc_valid'] and u['score_valid']==0 and not u['duration_valid']
  assert u['cycles']==int(timer[n]['cycles'])==b['cycles']==d['cycles']
  assert b['retired']==d['slot0_retired']+d['slot1_retired']
  rows.append(dict(mode=u['mode'],iterations=u['iterations'],cycles=b['cycles'],retired=b['retired'],ipc=b['retired']/b['cycles']))
 return r,rows
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--release',action='store_true');a=ap.parse_args()
 checks={}
 for rel in ('rv32i/mul_pair_combo/latest_run.json','m_core/mul_pair_combo/result.json','lsu_directed/result.json','mul_directed/result.json','machine/final/core_tests.json'):
  r=read(P/'reports'/rel);assert r['status']=='passed',rel;checks[rel]='passed'
 previous=P.parent/'rv32im_evolve4'
 for rel in ('wide_cache_units/result.json','m_unit/result.json','m_mapped/result.json'):
  r=read(previous/'reports'/rel);assert r['status']=='passed',rel
  checks['reference/evolve4_checks/'+rel]='passed'
  shutil.copytree(previous/'reports'/Path(rel).parent,P/'reference/evolve4_checks'/Path(rel).parent,dirs_exist_ok=True)
 assert (previous/'rtl/rv32_muldiv.v').read_bytes()==(P/'rtl/rv32_muldiv.v').read_bytes()
 assert (previous/'rtl/cache/rv32_burst_cache_2way.v').read_bytes()==(P/'rtl/cache/rv32_burst_cache_2way.v').read_bytes()
 trials={};table=[]
 evidence={
  'dual1':P.parent/'rv32im_dual1/reports/final_coremark/dual',
  'compiler_lto':P.parent/'rv32im_evolve1/reports/compiler/gcc15_O2_lto/run8',
  'branch_pair':P.parent/'rv32im_evolve2/reports/branch_cm8',
  'shared_lsu':P.parent/'rv32im_evolve3/reports/shared_cm8_v3',
  'fast_store':previous/'reports/store_cm8','fast_mul':previous/'reports/mul_cm8',
  'fast_both':previous/'reports/both_cm8','tuned_without_mul_pair':previous/'reports/final_measurements/tuned_lto',
  'balanced':P/'reports/balanced_final8','speed':P/'reports/mul_pair_lto_v2','unroll_candidate':P/'reports/mul_pair_unroll_v2',
 }
 for label,folder in evidence.items():
  r,rows=measure(folder);assert [x['iterations'] for x in rows]==[1,1,8,8]
  trials[label]=dict(evidence=str(folder),runs=rows)
  row=rows[2];validation=rows[3]
  table.append(dict(variant=label,performance_cycles=row['cycles'],performance_retired=row['retired'],performance_ipc=row['ipc'],validation_cycles=validation['cycles'],validation_ipc=validation['ipc']))
 for name in ('balanced','speed'):
  r,rows=measure(evidence[name]);assert rows[2]['retired']==2451118 and rows[3]['retired']==2450167
  check_dual_boot((evidence[name]/'coremark_uart.txt').read_text(encoding='utf-8'),r['prepared'])
  for rel,digest in r['prepared']['source_sha256'].items():assert sha(P/rel)==digest,rel
 assert trials['speed']['runs'][2]['cycles']<trials['unroll_candidate']['runs'][2]['cycles']
 # Preserve all seven predictor choices, including the non-winning gshare.
 jobs=read(previous/'reports/predictor_sweep/jobs.json');assert len(jobs)==7 and all(x['passed'] for x in jobs.values())
 predictors=[]
 for config in sorted(jobs):
  r,rows=measure(previous/'reports/predictor_sweep'/config)
  predictors.append(dict(config=config,performance_cycles=rows[2]['cycles'],validation_cycles=rows[3]['cycles']))
 assert min(predictors,key=lambda x:x['performance_cycles']+x['validation_cycles'])['config']=='fast_combo'
 for script in ('test_evolve_log.py',):
  run=subprocess.run([sys.executable,str(P/'tests'/script),'-v'],capture_output=True,text=True)
  (P/'reports'/script.replace('.py','.log')).write_text(run.stdout+run.stderr,encoding='utf-8');assert run.returncode==0,run.stderr
 passed={};attempts=[]
 for f in sorted((P/'reports/pds').glob('*/build.json')):
  r=read(f);attempts.append(dict(report=f.relative_to(P).as_posix(),status=r['status'],config=r['config'],error=r.get('error')))
  if r['status']!='passed':continue
  label='balanced' if r['config']=='mul_pair' else 'speed' if r['config']=='mul_pair_combo' else None
  if not label:continue
  t=(f.parent/'post_route_timing.rtr').read_text(encoding='utf-8')
  assert sorted({abs(float(x)) for x in re.findall(r'clock uncertainty\s+([-\d.]+)',t)})==[0.2,0.25]
  assert re.search(r'sys_clk\s+40\.0000\s',t)
  assert sha(P/r['bitstream'])==r['bitstream_sha256']
  measured,_=measure(evidence[label]);assert r['prepared']['source_sha256']==measured['prepared']['source_sha256']
  assert r['audit']['dsp_count']==4 and r['audit']['drm36k_total']==16 and r['audit']['rom_words_verified']==8192
  assert r['audit']['firmware_rom_sha256']==sha(P.parents[1]/'work/evolve1_build_gcc15_O2_lto/firmware/coremark/firmware_rom.hex')
  if label=='speed' and label in passed and passed[label]['artifact_label']=='speed_cluster_s1':continue
  passed[label]=dict(config=r['config'],pds_report=f.relative_to(P).as_posix(),bitstream=r['bitstream'],bitstream_sha256=r['bitstream_sha256'],artifact_label=r['artifact_label'],audit=r['audit'],
                     slot1_capabilities=['RV32I ALU/LUI/AUIPC','branch/JAL/JALR','load/store through shared LSU','MUL/MULH/MULHSU/MULHU through shared MDU'])
 with (P/'reports/ipc_comparison.csv').open('w',newline='',encoding='utf-8-sig') as stream:
  writer=csv.DictWriter(stream,fieldnames=table[0].keys());writer.writeheader();writer.writerows(table)
 summary=dict(stage='EVOLVE5',status='passed_offline' if set(passed)=={'balanced','speed'} else 'timing_pending',hardware_tested=False,
              formal_coremark_score=None,comparison=table,measurements=trials,predictor_comparison=predictors,tests=checks,pds_attempts=attempts,
              implementations=passed,software_selected='GCC15.2 O2+LTO',retired_count_source='independently observed ordered retire ports, cross-checked with minstret snapshots',
              deferred='Full OoO, wider-than-two issue, new ISA extensions and PGO are not implemented in this same-RV32IM optimization release.')
 (P/'reports/summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
 if a.release:
  assert set(passed)=={'balanced','speed'},'Both final hardware configurations need original-constraint timing sign-off'
  protected={}
  for name,expected in read(P/'baseline.json')['protected'].items():
   root=P.parent/name;m=root/'FILE_SHA256.txt';assert sha(m)==expected['manifest_sha256']
   lines=m.read_text(encoding='utf-8').splitlines();assert len(lines)==expected['files']
   for line in lines:
    digest,rel=line.split('  ',1);assert sha(root/rel)==digest,(name,rel)
   protected[name]=dict(status='unchanged',files=len(lines))
  original=read(P/'baseline.json')['original_sources']
  for rel in ('board/rk3568_mes2l100h/pins.json','board/rk3568_mes2l100h/timing.fdc','board/rk3568_mes2l100h/electrical_review.json'):
   assert sha(P/rel)==original[rel],rel
  release=dict(stage='EVOLVE5',status='offline_verified_board_pending',default='speed',default_iterations=2048,clock_hz=25000000,
               hardware_tested=False,variants=passed,protected=protected,firmware_build='EVOLVE1_BOARD',firmware_bin_sha256=sha(P.parents[1]/'work/evolve1_build_gcc15_O2_lto/firmware/coremark/firmware.bin'),
               notes='Firmware build name tracks the frozen compiler-stage binary; MIMPID/FRONT_CFG distinguish the EVOLVE5 hardware.')
  (P/'release.json').write_text(json.dumps(release,indent=2),encoding='utf-8')
 print(json.dumps(dict(status=summary['status'],comparison=table,passed_pds=list(passed)),indent=2))
if __name__=='__main__':main()
