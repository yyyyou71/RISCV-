"""Recalculate comparisons from raw UART/CSV, and optionally sign off a release."""
import argparse,csv,hashlib,json,re,subprocess,sys
from pathlib import Path
from regress import PROJECT as P
from parse_coremark import parse_text
from verify_front_log import expected_front
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def measure(folder):
    report=read(folder/'simulation.json');assert report['status']=='passed'
    text=(folder/'coremark_uart.txt').read_text();parsed=parse_text(text,'simulation')
    bus=list(csv.DictReader((folder/'bus_metrics.csv').open()))
    bp=list(csv.DictReader((folder/'bp_stats.csv').open()))
    front=list(csv.DictReader((folder/'front_metrics.csv').open()))
    samples=list(csv.DictReader((folder/'timer_intervals.csv').open()))
    assert len(parsed['runs'])==len(bus)==len(front)==len(samples)==4
    headers=re.findall(r'FRONT_CFG=([0-9a-fA-F]{8}) GSHARE=(\d+) PHT_BITS=(\d+) RAS=(\d+) FETCH=(\d+) LOAD_FWD=(\d+)',text)
    assert len(headers)==1
    assert [int(headers[0][0],16)]+list(map(int,headers[0][1:]))==expected_front(report['prepared'])
    assert (folder/'firmware/firmware.bin').read_bytes()==(P/'reference/frozen_front1/firmware.bin').read_bytes()
    rows=[]
    for n,uart in enumerate(parsed['runs']):
        assert uart['standard_crc_valid'] and uart['score_valid']==0 and not uart['duration_valid']
        assert uart['cycles']==int(bus[n]['cycles'])==int(front[n]['cycles'])==int(samples[n]['cycles'])
        rows.append({'mode':uart['mode'],'iterations':uart['iterations'],'cycles':uart['cycles'],
                     'retired':int(bus[n]['retired']),'next_pc_misses':int(bp[n]['next_pc_misses']),
                     **{k:int(v) for k,v in front[n].items() if k not in ('run','cycles')}})
    return report,rows
def main():
    p=argparse.ArgumentParser();p.add_argument('--release',action='store_true');a=p.parse_args()
    candidates={}
    for group in ('sweep1','bypass1','combos1','balance1'):
        jobs=read(P/'reports'/group/'jobs.json');assert all(row['passed'] for row in jobs.values())
        for config in sorted(jobs):
            folder=P/'reports'/group/config;report,rows=measure(folder)
            assert [r['iterations'] for r in rows]==[1,1,2,2]
            candidates[config]={'evidence':folder.relative_to(P).as_posix(),'runs':rows,'prepared':report['prepared']}
    assert len(candidates)==24
    base=candidates['baseline']['runs'];table=[]
    for config,row in candidates.items():
        assert [x['retired'] for x in row['runs']]==[x['retired'] for x in base]
        f=row['prepared']['frontend'];b=row['prepared']['branch_prediction']
        record={'config':config,'btb':b['entries'],'gshare':int(f['gshare_enabled']),'pht':1<<f['pht_bits'] if f['gshare_enabled'] else 0,
                'ras':f['ras_depth'],'fetch_depth':f['fetch_depth'],'fetch_bypass':int(f.get('fetch_bypass',False)),'load_forward':int(f['load_forward']),
                'performance_cycles':row['runs'][2]['cycles'],'validation_cycles':row['runs'][3]['cycles'],
                'speedup_p':base[2]['cycles']/row['runs'][2]['cycles'],'speedup_v':base[3]['cycles']/row['runs'][3]['cycles'],
                'luts':'','registers':''}
        syn=P/'reports/synthesis'/config/'result.json'
        if syn.exists():
            s=read(syn);assert s['status']=='passed_synthesis_only';record.update(luts=s['luts'],registers=s['registers'])
        table.append(record)
    with (P/'reports/comparison.csv').open('w',newline='',encoding='utf-8-sig') as stream:
        w=csv.DictWriter(stream,fieldnames=table[0].keys());w.writeheader();w.writerows(table)
    final={}
    for config in ('baseline','lean32','combo256'):
        report,rows=measure(P/'reports/final8'/config)
        assert [r['iterations'] for r in rows]==[1,1,8,8]
        for source,digest in report['prepared']['source_sha256'].items():assert sha(P/source)==digest,source
        assert [r['cycles'] for r in rows[:2]]==[r['cycles'] for r in candidates[config]['runs'][:2]]
        final[config]={'runs':rows,'prepared':report['prepared']}
    base=final['baseline']['runs']
    ratios={config:{mode:base[i]['cycles']/final[config]['runs'][i]['cycles'] for mode,i in [('performance',2),('validation',3)]} for config in ('lean32','combo256')}
    checks={}
    paths=['front_predict_units/result.json','front_fifo_units/result.json','rv32i/aggressive/latest_run.json']
    paths += [f'{kind}/{config}/{name}' for config in ('aggressive','lean32','combo256') for kind,name in [('m_core','result.json'),('machine','core_tests.json')]]
    paths += [f'fetch_fault/{config}_fixed/result.json' for config in ('lean32','combo256')]
    for rel in paths:
        data=read(P/'reports'/rel);assert data['status']=='passed',rel;checks[rel]='passed'
    for name in ('test_m_log.py','test_front_log.py'):
        run=subprocess.run([sys.executable,str(P/'tests'/name),'-v'],capture_output=True,text=True)
        (P/'reports'/name.replace('.py','.log')).write_text(run.stdout+run.stderr)
        assert run.returncode==0
    attempts=[];passed={}
    for file in sorted((P/'reports/pds').glob('*/build.json')):
        result=read(file);attempts.append({'path':file.relative_to(P).as_posix(),'status':result['status'],'config':result.get('config',result['variant']),'error':result.get('error')})
        if result['status']=='passed':
            config=result['config']
            timing=(file.parent/'post_route_timing.rtr').read_text()
            uncertainty=sorted({abs(float(x)) for x in re.findall(r'clock uncertainty\s+([-\d.]+)',timing)})
            assert uncertainty==[0.2,0.25],('Unexpected timing uncertainty',config,uncertainty)
            assert re.search(r'sys_clk\s+40\.0000\s',timing)
            for source,digest in result['prepared']['source_sha256'].items():assert sha(P/source)==digest
            assert sha(P/result['bitstream'])==result['bitstream_sha256']
            assert result['audit']['firmware_rom_sha256']==sha(P/'reference/frozen_front1/firmware_rom.hex')
            assert result['prepared']['source_sha256']==final[config]['prepared']['source_sha256']
            passed[config]={'pds_report':file.relative_to(P).as_posix(),'bitstream':result['bitstream'],'sha256':result['bitstream_sha256'],'audit':result['audit'],
                            'actual_timing_uncertainty_ns':{'setup_with_tool_jitter':0.25,'hold':0.2},'clock_period_ns':40}
    summary={'status':'passed_offline' if len(passed)==3 else 'timing_signoff_pending','hardware_tested':False,
             'formal_coremark_score':None,'measured_configurations':len(candidates),'short_coremark_runs':108,
             'comparison':table,'final8':final,'speedup_ratios':ratios,'tests':checks,'log_tests':21,
             'pds_attempts':attempts,'passed_implementations':passed,'recommended':'lean32',
             'recommendation':'Use low-cost fetch bypass and load-result forwarding by default; retain combo256 as the larger BTB/RAS speed comparison.'}
    (P/'reports/summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    if a.release:
        assert set(passed)=={'baseline','lean32','combo256'},'All three implementations must meet original timing constraints'
        protected={}
        baseline=read(P/'baseline.json')
        for name,expected in baseline['protected'].items():
            root=P.parent/name;manifest=root/'FILE_SHA256.txt';assert sha(manifest)==expected['manifest_sha256']
            rows=manifest.read_text(encoding='utf-8').splitlines();assert len(rows)==expected['files']
            for row in rows:
                digest,relative=row.split('  ',1);assert sha(root/relative)==digest,(name,relative)
            protected[name]={'status':'unchanged','files':len(rows)}
        for rel in ('board/rk3568_mes2l100h/pins.json','board/rk3568_mes2l100h/timing.fdc','board/rk3568_mes2l100h/electrical_review.json'):
            assert sha(P/rel)==baseline['original_sources'][rel]
        release={'stage':'FRONT1','status':'offline_verified_board_pending','default':'lean32','hardware_tested':False,
                 'clock_hz':25000000,'default_iterations':2048,'variants':passed,'protected':protected}
        (P/'release.json').write_text(json.dumps(release,indent=2),encoding='utf-8')
    print(json.dumps({'status':summary['status'],'ratios':ratios,'passed_pds':list(passed)},indent=2))
if __name__=='__main__':main()
