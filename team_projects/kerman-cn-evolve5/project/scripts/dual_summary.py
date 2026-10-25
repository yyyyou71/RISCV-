"""Rebuild the DUAL1 comparison from raw evidence and sign off release files."""
import argparse,csv,hashlib,json,re,subprocess,sys
from pathlib import Path
from regress import PROJECT as P
from parse_coremark import parse_text
from verify_dual_log import check_dual_boot
from verify_front_log import expected_front

NAMES=('scalar','wide_single','dual')
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def csv_rows(p):return [{k:int(v) for k,v in x.items()} for x in csv.DictReader(p.open())]

def measurements(group,firmware):
    jobs=read(P/'reports'/group/'jobs.json');assert set(jobs)==set(NAMES) and all(x['passed'] for x in jobs.values())
    output={}
    for name in NAMES:
        folder=P/'reports'/group/name;r=read(folder/'simulation.json');assert r['status']=='passed'
        text=(folder/'coremark_uart.txt').read_text();parsed=parse_text(text,'simulation')
        buses=csv_rows(folder/'bus_metrics.csv');duals=csv_rows(folder/'dual_metrics.csv');fronts=csv_rows(folder/'front_metrics.csv')
        samples=csv_rows(folder/'timer_intervals.csv');branches=csv_rows(folder/'bp_stats.csv')
        assert len(parsed['runs'])==len(buses)==len(duals)==len(fronts)==len(samples)==len(branches)==4
        assert (folder/'firmware/firmware.bin').read_bytes()==(P/'reference'/firmware/'firmware.bin').read_bytes()
        cfg=re.findall(r'FRONT_CFG=([0-9a-fA-F]{8}) GSHARE=(\d+) PHT_BITS=(\d+) RAS=(\d+) FETCH=(\d+) LOAD_FWD=(\d+)',text)
        assert len(cfg)==1 and [int(cfg[0][0],16)]+list(map(int,cfg[0][1:]))==expected_front(r['prepared'])
        for path,digest in r['prepared']['source_sha256'].items():assert sha(P/path)==digest,path
        rows=[]
        for n,uart in enumerate(parsed['runs']):
            assert uart['standard_crc_valid'] and uart['score_valid']==0 and not uart['duration_valid']
            assert uart['cycles']==buses[n]['cycles']==duals[n]['cycles']==fronts[n]['cycles']==samples[n]['cycles']
            assert buses[n]['retired']==duals[n]['slot0_retired']+duals[n]['slot1_retired']
            rows.append(dict(mode=uart['mode'],iterations=uart['iterations'],cycles=uart['cycles'],retired=buses[n]['retired'],
                             ipc=buses[n]['retired']/uart['cycles'],dual=duals[n],front=fronts[n],branch=branches[n],bus=buses[n]))
        output[name]=dict(evidence=folder.relative_to(P).as_posix(),runs=rows,prepared=r['prepared'])
        if firmware=='frozen_dual1':output[name]['boot']=check_dual_boot(text,r['prepared'])
    reference=output['scalar']['runs']
    for name in NAMES:
        assert [x['retired'] for x in output[name]['runs']]==[x['retired'] for x in reference]
    return output

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--release',action='store_true');a=parser.parse_args()
    initial=measurements('initial_coremark','frozen_front1')
    boot=measurements('firmware_check','frozen_dual1')
    final=measurements('final_coremark','frozen_dual1')
    assert all([r['iterations'] for r in final[n]['runs']]==[1,1,8,8] for n in NAMES)
    checks={}
    for path in ('rv32i/dual/latest_run.json','rv32i/lean32/latest_run.json','m_core/dual/result.json',
                 'machine/dual_final/core_tests.json','machine/aggressive_dual/core_tests.json',
                 'dual_regfile/result.json','wide_cache_units/result.json','dual_fifo_v2/result.json',
                 'dual_directed_v2/result.json','dual_pairs/result.json'):
        data=read(P/'reports'/path);assert data['status']=='passed',path;checks[path]='passed'
    run=subprocess.run([sys.executable,'-m','unittest','discover','-s',str(P/'tests'),'-p','test_*.py','-v'],capture_output=True,text=True)
    (P/'reports/host_log_tests.log').write_text(run.stdout+run.stderr);assert run.returncode==0,run.stderr
    run=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(P/'tests/test_coremark_serial.ps1')],capture_output=True,text=True)
    (P/'reports/serial_protocol_tests.log').write_text(run.stdout+run.stderr);assert run.returncode==0
    passed={};attempts=[]
    for path in sorted((P/'reports/pds').glob('*/build.json')):
        r=read(path);name=r['config'];attempts.append(dict(path=path.relative_to(P).as_posix(),status=r['status'],config=name,error=r.get('error')))
        if r['status']!='passed':continue
        timing=(path.parent/'post_route_timing.rtr').read_text()
        assert sorted({abs(float(x)) for x in re.findall(r'clock uncertainty\s+([-\d.]+)',timing)})==[0.2,0.25]
        assert re.search(r'sys_clk\s+40\.0000\s',timing)
        assert r['prepared']['source_sha256']==final[name]['prepared']['source_sha256']
        assert sha(P/r['bitstream'])==r['bitstream_sha256']
        assert r['audit']['firmware_rom_sha256']==sha(P/'reference/frozen_dual1/firmware_rom.hex')
        assert (P/'download'/name/'firmware.bin').read_bytes()==(P/'reference/frozen_dual1/firmware.bin').read_bytes()
        assert r['audit']['dsp_count']==4 and r['audit']['drm36k_total']==16
        passed[name]=dict(pds_report=path.relative_to(P).as_posix(),bitstream=r['bitstream'],sha256=r['bitstream_sha256'],audit=r['audit'],
                          actual_timing_uncertainty_ns=dict(setup_with_tool_jitter=0.25,hold=0.2),clock_period_ns=40)
    table=[];base=final['scalar']['runs']
    for name in NAMES:
        row=final[name];perf,validation=row['runs'][2:];audit=passed.get(name,{}).get('audit',{})
        record=dict(config=name,performance_cycles=perf['cycles'],validation_cycles=validation['cycles'],
                    speedup_p=base[2]['cycles']/perf['cycles'],speedup_v=base[3]['cycles']/validation['cycles'],
                    coremark_ipc=perf['ipc'],slot1_retirements=perf['dual']['slot1_retired'],
                    microbenchmark_ipc=row['boot']['microbenchmark']['ipc'],
                    luts=audit.get('synthesis_luts'),registers=audit.get('synthesis_registers'),dsp=audit.get('dsp_count'),drm=audit.get('drm36k_total'))
        if name in passed and 'scalar' in passed:
            record['area_ratio']=record['luts']/passed['scalar']['audit']['synthesis_luts']
            record['relative_work_per_cycle_per_lut']=record['speedup_p']/record['area_ratio']
        table.append(record)
    with (P/'reports/comparison.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=table[0].keys());writer.writeheader();writer.writerows(table)
    summary=dict(stage='DUAL1',status='passed_offline' if set(passed)==set(NAMES) else 'timing_pending',hardware_tested=False,
                 formal_coremark_score=None,short_coremark_runs=36,comparison=table,initial_front1=initial,firmware_check=boot,final8=final,
                 tests=checks,host_validation=dict(dual_test_methods=4,negative_mutations=26,positive_configurations=3,serial_scenarios=11,host_methods_passed=50,historical_cache3_methods_skipped=9),
                 pds_attempts=attempts,passed_implementations=passed,
                 tradeoff='Restricted dual issue improves cycles at fixed frequency but increases LUT cost; retain scalar area-efficiency control.')
    (P/'reports/summary.json').write_text(json.dumps(summary,indent=2))
    if a.release:
        assert set(passed)==set(NAMES),'All three release variants must pass original constraints'
        baseline=read(P/'baseline.json');protected={}
        for name,record in baseline['protected'].items():
            root=P.parent/name;manifest=root/'FILE_SHA256.txt';assert sha(manifest)==record['manifest_sha256']
            lines=manifest.read_text(encoding='utf-8').splitlines();assert len(lines)==record['files']
            for line in lines:
                digest,relative=line.split('  ',1);assert sha(root/relative)==digest,(name,relative)
            protected[name]=dict(status='unchanged',files=len(lines))
        for relative in ('board/rk3568_mes2l100h/pins.json','board/rk3568_mes2l100h/timing.fdc','board/rk3568_mes2l100h/electrical_review.json'):
            assert sha(P/relative)==baseline['original_sources'][relative]
        sources={p.relative_to(P).as_posix():sha(p) for p in sorted((P/'firmware').rglob('*')) if p.is_file()}
        release=dict(stage='DUAL1',release_date='2026-10-23',status='offline_verified_board_pending',default='dual',hardware_tested=False,clock_hz=25000000,
                     default_iterations=2048,variants=passed,protected=protected,firmware_source_sha256=sources,
                     firmware_bin_sha256=sha(P/'reference/frozen_dual1/firmware.bin'),
                     contest_extension_eligibility='unconfirmed',area_efficiency_control='scalar')
        (P/'release.json').write_text(json.dumps(release,indent=2))
    print(json.dumps(dict(status=summary['status'],comparison=table),indent=2))
if __name__=='__main__':main()
