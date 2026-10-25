"""Cross-check final software, RTL, PDS evidence and calculate short-run deltas."""
import csv,hashlib,json,re,subprocess,sys
from pathlib import Path
from regress import PROJECT as P

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path): return json.loads((P/path).read_text(encoding='utf-8'))
def main():
    measurements={}; variants={}
    for name in ('native','software'):
        relative=f'reports/pds/s6_{name}/build.json'; pds=read(relative)
        sim=read(f'reports/coremark/measured_{name}/simulation.json')
        assert pds['status']==sim['status']=='passed'
        assert pds['audit']['dsp_count']==4 and pds['audit']['latches']==0
        for source,h in pds['prepared']['source_sha256'].items(): assert sha(P/source)==h,source
        assert pds['prepared']['source_sha256']==sim['prepared']['source_sha256']
        assert sha(P/pds['bitstream'])==pds['bitstream_sha256']
        rom=P/f'download/{name}/firmware_rom.hex'
        assert sha(rom)==pds['audit']['firmware_rom_sha256']
        assert rom.read_bytes()==(P/f'reports/coremark/measured_{name}/firmware/firmware_rom.hex').read_bytes()
        assert sha(P/f'pds_projects/{name}/timing.fdc')==sha(P/'board/rk3568_mes2l100h/timing.fdc')
        assert sha(P/f'pds_projects/{name}/rv32_board_design.v')==pds['audit']['combined_rtl_sha256']
        dis=(P/f'download/{name}/firmware.dis').read_text()
        mcounts={op:len(re.findall(r'\t'+op+r'\s',dis)) for op in ('mul','mulh','mulhsu','mulhu','div','divu','rem','remu')}
        assert all(mcounts.values()) if name=='native' else not any(mcounts.values())
        bus=list(csv.DictReader((P/f'reports/coremark/measured_{name}/bus_metrics.csv').open()))
        bp=list(csv.DictReader((P/f'reports/coremark/measured_{name}/bp_stats.csv').open()))
        rows=[]
        for n,row in enumerate(sim['results']['runs']):
            assert row['standard_crc_valid'] and not row['score_valid']
            assert row['cycles']==int(bus[n]['cycles'])
            if row['iterations']!=8: continue
            rows.append(dict(mode=row['mode'],iterations=8,cycles=row['cycles'],retired=int(bus[n]['retired']),
                             cpi=row['cycles']/int(bus[n]['retired']),next_pc_misses=int(bp[n]['next_pc_misses'])))
        assert len(rows)==2
        measurements[name]=rows
        variants[name]={'pds_report':relative,'simulation_report':f'reports/coremark/measured_{name}/simulation.json',
                        'bitstream':pds['bitstream'],'sha256':pds['bitstream_sha256'],
                        'software_isa':pds['prepared']['firmware']['isa'],
                        'm_instruction_sites':mcounts,'image_bytes':pds['prepared']['firmware']['image_bytes']}
    checks={}
    for name,file in [('arithmetic','reports/m_unit/result.json'),('mapped_arithmetic','reports/m_mapped/result.json'),
                      ('cpu_m','reports/m_core/result.json'),('cpu_i','reports/latest_run.json'),
                      ('machine','reports/machine_final/core_tests.json'),('fetch_fault','reports/fetch_fault/fixed/result.json')]:
        report=read(file); assert report['status']=='passed'; checks[name]=file
    test=subprocess.run([sys.executable,str(P/'tests/test_m_log.py'),'-v'],capture_output=True,text=True)
    (P/'reports/m_log_tests.log').write_text(test.stdout+test.stderr)
    assert test.returncode==0
    comparisons=[]
    for native,software in zip(measurements['native'],measurements['software']):
        comparisons.append({'mode':native['mode'],'speedup':software['cycles']/native['cycles'],
                            'cycle_reduction_percent':100*(1-native['cycles']/software['cycles']),
                            'retired_reduction_percent':100*(1-native['retired']/software['retired']),
                            'next_pc_miss_reduction_percent':100*(1-native['next_pc_misses']/software['next_pc_misses'])})
    baseline=read('reference/cache3_pds.json')['audit']; final=read('reports/pds/s6_native/audit.json')
    protected={}
    original=read('baseline.json')['original_sources']
    for relative in ('board/rk3568_mes2l100h/timing.fdc','board/rk3568_mes2l100h/pins.json','board/rk3568_mes2l100h/electrical_review.json'):
        assert sha(P/relative)==original[relative],'Inherited board constraint changed: '+relative
    for name,expected in read('baseline.json')['protected'].items():
        root=P.parent/name; manifest=root/'FILE_SHA256.txt'
        assert sha(manifest)==expected['manifest_sha256']
        rows=manifest.read_text(encoding='utf-8').splitlines(); assert len(rows)==expected['files']
        for row in rows:
            digest,relative=row.split('  ',1); assert sha(root/relative)==digest,(name,relative)
        protected[name]={'status':'unchanged','files':len(rows)}
    summary={'status':'passed_offline','hardware_tested':False,'formal_extension_score':None,
             'choice':'RV32IM_Zicsr','measurements':measurements,'comparisons':comparisons,
             'resources':{k:{'baseline':baseline[k],'front1':final[k]} for k in ('synthesis_luts','synthesis_registers','drm36k_total')},
             'dsp_count':4,'dsp_device_total':240,'timing':final['timing'],'tests':checks,
             'log_validator_tests':9,'protected_releases':protected,'original_electrical_and_timing_files_unchanged':True,
             'notes':['1/1/8/8 RTL runs are functional/performance comparisons, never formal board scores.',
                      'Software control uses the same M-capable RTL with RV32I code, not the frozen CACHE3 binary.',
                      'No MEXT1 board programming, physical Fmax measurement, or contest eligibility confirmation.']}
    (P/'reports/summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    release={'stage':'MEXT1','status':'offline_verified_board_pending','hardware_tested':False,
             'default_iterations':2048,'clock_hz':25000000,'variants':variants,'evidence':'reports/summary.json'}
    (P/'release.json').write_text(json.dumps(release,indent=2),encoding='utf-8')
    print(json.dumps({'comparisons':comparisons,'resources':summary['resources'],'variants':variants},indent=2))
if __name__=='__main__': main()
