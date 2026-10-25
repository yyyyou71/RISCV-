"""Run unaccelerated short CoreMark tests on the actual RTL and UART pins."""
import argparse,csv,hashlib,json,os,re,shutil
from datetime import datetime,timezone
from pathlib import Path
from regress import PROJECT,run_command
from build_coremark import build_coremark,DEFAULT_GCC
from prepare_board import prepare
from parse_coremark import parse_text
from platform_identity import check_runs
from front_configs import CONFIGS

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--gcc',type=Path,default=DEFAULT_GCC)
    p.add_argument('--build-dir',type=Path)
    p.add_argument('--iterations',type=int,default=512)
    p.add_argument('--bp-enable',type=int,choices=(0,1),default=1)
    p.add_argument('--bp-index-bits',type=int,default=5)
    p.add_argument('--reports',type=Path)
    p.add_argument('--cache-enable',type=int,choices=(0,1),default=1)
    p.add_argument('--burst-fill',type=int,choices=(0,1),default=1)
    p.add_argument('--first-wait',type=int,default=0)
    p.add_argument('--beat-gap',type=int,default=0)
    p.add_argument('--software-isa',choices=('native','software'),default='native')
    p.add_argument('--measure-iterations',type=int,default=2)
    p.add_argument('--config',choices=CONFIGS,default='baseline')
    p.add_argument('--frozen',action='store_true')
    p.add_argument('--firmware-ref',choices=('front1','dual1'),default='front1')
    p.add_argument('--firmware-dir',type=Path)
    p.add_argument('--profile',action='store_true')
    a=p.parse_args()
    name=f'{a.config}_{a.software_isa}_c{a.cache_enable}_b{a.burst_fill}_w{a.first_wait}_g{a.beat_gap}_bp{a.bp_enable}'
    build=(a.build_dir or PROJECT.parents[1]/'work'/f'evolve5_coremark_{name}').resolve()
    reports=a.reports or PROJECT/'reports/backend/coremark'/name; reports.mkdir(parents=True,exist_ok=True)
    state={'status':'running','started_utc':datetime.now(timezone.utc).isoformat()}
    report=reports/'simulation.json'; report.write_text(json.dumps(state),encoding='utf-8')
    try:
        if a.firmware_dir:
            folder=a.firmware_dir.resolve()
            firmware=(folder,json.loads((folder/'build.json').read_text(encoding='utf-8')))
        elif a.frozen:
            assert a.software_isa=='native'
            folder=PROJECT/'reference'/('frozen_'+a.firmware_ref)
            firmware=(folder,json.loads((folder/'build.json').read_text()))
        else: firmware=build_coremark(build,a.gcc,a.iterations,a.software_isa)
        prepared=prepare(build,a.gcc,firmware=firmware,bp_enable=a.bp_enable,icache_enable=a.cache_enable,dcache_enable=a.cache_enable,
                         burst_fill=a.burst_fill,first_wait=a.first_wait,beat_gap=a.beat_gap,**CONFIGS[a.config])
        env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
        assert 2<=a.measure_iterations<=8
        tb=(PROJECT/'sim/tb_coremark.sv').read_text().replace('p 2\\n',f'p {a.measure_iterations}\\n').replace('v 2\\n',f'v {a.measure_iterations}\\n')
        tb=tb.replace('bp_profile_monitor branch_statistics();','front_profile_monitor front_statistics();\n    bp_profile_monitor branch_statistics();')
        tb=tb.replace('front_profile_monitor front_statistics();','front_profile_monitor front_statistics();\n    dual_profile_monitor dual_statistics();')
        if a.profile:tb=tb.replace('dual_profile_monitor dual_statistics();','dual_profile_monitor dual_statistics();\n    evolve_profile_monitor detailed_statistics();')
        (build/'tb_coremark.sv').write_text(tb)
        extra=[PROJECT/'sim/evolve_profile_monitor.sv'] if a.profile else []
        run_command([vb/'xvlog.bat','-sv',build/'rv32_board_design.v',build/'tb_coremark.sv',PROJECT/'sim/bp_profile_monitor.sv',PROJECT/'sim/burst_profile_monitor.sv',PROJECT/'sim/front_profile_monitor.sv',PROJECT/'sim/dual_profile_monitor.sv',*extra],build,build/'compile.log',env)
        run_command([vb/'xelab.bat','tb_coremark','-s','coremark_sim','-mt','4'],build,build/'elaborate.log',env)
        out=run_command([vb/'xsim.bat','coremark_sim','-runall'],build,build/'simulate.log',env,timeout=900)
        if any(marker not in out for marker in ('COREMARK_SIM_PASS','COREMARK_TIMER_ROLLOVER_PASS','BP_STATS_PASS','BURST_PROFILE_PASS','FRONT_PROFILE_PASS','DUAL_PROFILE_PASS')): raise RuntimeError(out[-7000:])
        match=re.search(r'CACHE_ACTIVITY ih=(\d+) im=(\d+) dh=(\d+) dm=(\d+) wh=(\d+) wm=(\d+)',out)
        assert match,'Missing cache activity observations'
        activity=dict(zip(('instruction_hits','instruction_misses','data_read_hits','data_read_misses','data_write_hits','data_write_misses'),map(int,match.groups())))
        assert all(value>0 for value in activity.values()) if a.cache_enable else all(value==0 for value in activity.values())
        parsed=parse_text((build/'coremark_uart.txt').read_text(encoding='ascii'),'simulation')
        uart_text=(build/'coremark_uart.txt').read_text(encoding='ascii')
        assert 'MISA=40001100 HW_M=1' in uart_text
        assert ('M_CHECK PASS vectors=128 instructions=8' if a.software_isa=='native' else 'M_CHECK SKIP software-ISA control') in uart_text
        if prepared['firmware']['build_id'] in ('DUAL1_BOARD','EVOLVE1_BOARD'):
            cfg=CONFIGS[a.config];expected_issue=0xd1000000|cfg['dual_enable']|(cfg['wide_fetch']<<1)
            assert f'ISSUE_CFG={expected_issue:08x} ISSUE_WIDTH={1+cfg["dual_enable"]} FETCH_WORDS={1+cfg["wide_fetch"]}' in uart_text
            micro=re.search(r'DUAL_CHECK PASS iterations=1024 cycles=(\d+) instret=(\d+) pairs=(\d+)',uart_text)
            assert micro and int(micro[2])==34818
            if cfg['dual_enable'] and cfg['wide_fetch'] and a.cache_enable: assert int(micro[2])>int(micro[1]) and int(micro[3])>0
        assert len(parsed['runs'])==4
        identity=check_runs((build/'coremark_uart.txt').read_text(),prepared,prepared['firmware']['build_id'],prepared['firmware']['printed_flags'])
        assert identity['identity_passed'] and identity['flags_passed'] and len(identity['identity_checks'])==4
        intervals=list(csv.DictReader((build/'timer_intervals.csv').open()))
        for row,reference in zip(parsed['runs'],intervals):
            if not row['standard_crc_valid']: raise RuntimeError('CoreMark CRC failed')
            if row['cycles']!=int(reference['cycles']): raise RuntimeError('Printed cycles disagree with actual MMIO timer samples')
            if row['score_valid']!=0 or row['duration_valid']: raise RuntimeError('Short tests incorrectly labelled as reportable')
        bp_rows=[{k:int(v) for k,v in row.items()} for row in csv.DictReader((build/'bp_stats.csv').open())]
        assert len(bp_rows)==4
        for row in bp_rows:
            assert row['btb_hits']<=row['control_retired'] and row['next_pc_misses']<=row['control_retired']
            if not a.bp_enable: assert row['btb_hits']==0 and row['taken_predictions']==0
        bus_rows=[{k:int(v) for k,v in row.items()} for row in csv.DictReader((build/'bus_metrics.csv').open())]
        assert len(bus_rows)==4
        for row,uart in zip(bus_rows,parsed['runs']): assert row['cycles']==uart['cycles']
        front_rows=[{k:int(v) for k,v in row.items()} for row in csv.DictReader((build/'front_metrics.csv').open())]
        assert len(front_rows)==4 and all(row['cycles']==uart['cycles'] for row,uart in zip(front_rows,parsed['runs']))
        dual_rows=[{k:int(v) for k,v in row.items()} for row in csv.DictReader((build/'dual_metrics.csv').open())]
        assert len(dual_rows)==4
        for row,bus in zip(dual_rows,bus_rows):
            assert row['cycles']==bus['cycles'] and row['slot0_retired']+row['slot1_retired']==bus['retired']
            assert row['slot1_retired']>0 if CONFIGS[a.config]['dual_enable'] else row['slot1_retired']==0
        for n in ('compile.log','elaborate.log','simulate.log','coremark_uart.txt','timer_intervals.csv','bp_stats.csv','bus_metrics.csv','front_metrics.csv','dual_metrics.csv','tb_coremark.sv'):
            shutil.copy2(build/n,reports/n)
        if a.profile:
            assert 'EVOLVE_PROFILE_PASS' in out
            for n in ('evolve_metrics.csv','pc_metrics.csv'):shutil.copy2(build/n,reports/n)
        target=reports/'firmware'; target.mkdir(exist_ok=True)
        for path in firmware[0].iterdir():
            if path.is_file() and path.suffix!='.o': shutil.copy2(path,target/path.name)
        state.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),
                     prepared=prepared,results=parsed,timer_samples_match=True,branch_statistics=bp_rows,cache_activity=activity,bus_metrics=bus_rows,hardware_identity=identity,
                     timer_low_word_rollover_tested=True,
                     config=a.config,frozen_firmware=bool(a.frozen),front_metrics=front_rows,dual_metrics=dual_rows,
                     minimum_ten_seconds_bypassed=False,hardware_score_obtained=False)
        report.write_text(json.dumps(state,indent=2),encoding='utf-8')
        print('COREMARK_REGRESSION_PASS '+json.dumps([(x['mode'],x['iterations'],x['cycles']) for x in parsed['runs']]),flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc)); report.write_text(json.dumps(state,indent=2),encoding='utf-8'); raise

if __name__=='__main__': main()
