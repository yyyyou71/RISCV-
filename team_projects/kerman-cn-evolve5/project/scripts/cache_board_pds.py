import argparse,hashlib,json,os,re,shutil,subprocess
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT
from build_coremark import build_coremark,DEFAULT_GCC
from build_machine_demo import build_demo
from prepare_board import prepare,BOARD
from run_pds import license_path,signoff_errors
from audit_pds import audit
def main():
    p=argparse.ArgumentParser(); p.add_argument('--variant',choices=('burst','word','uncached','selftest'),default='burst')
    p.add_argument('--seed',type=int); p.add_argument('--hold-iterations',type=int)
    p.add_argument('--hold-margin-ps',type=int,default=0)
    p.add_argument('--clock-hold-margin-ps',type=int,default=100)
    p.add_argument('--srb-hold-margin-ps',type=int,default=200)
    p.add_argument('--hold-path-limit',type=int,default=15000)
    p.add_argument('--decongestion',type=int)
    group=p.add_mutually_exclusive_group()
    group.add_argument('--no-cluster',action='store_true',dest='no_cluster')
    group.add_argument('--cluster',action='store_false',dest='no_cluster')
    p.set_defaults(no_cluster=None)
    p.add_argument('--pds',type=Path,default=Path(r'C:\pango\PDS_2022.2-SP6.1'))
    a=p.parse_args(); name=a.variant
    recipe={'burst':(4,5,False,1),'selftest':(4,5,False,1),'word':(6,10,True,1),'uncached':(1,10,True,3)}[name]
    if a.seed is None: a.seed=recipe[0]
    if a.hold_iterations is None: a.hold_iterations=recipe[1]
    if a.no_cluster is None: a.no_cluster=recipe[2]
    if a.decongestion is None: a.decongestion=recipe[3]
    build=PROJECT.parents[1]/'work'/f'cache3_pds_{name}'; report=PROJECT/'reports/pds'/name; report.mkdir(parents=True,exist_ok=True)
    record={'status':'running','variant':name,'hardware_tested':False,'started_utc':datetime.now(timezone.utc).isoformat()}
    manifest=report/'build.json'; manifest.write_text(json.dumps(record))
    try:
        assert not signoff_errors(json.loads((BOARD/'electrical_review.json').read_text()))
        fw=build_demo(build) if name=='selftest' else build_coremark(build,DEFAULT_GCC,512)
        enabled=int(name!='uncached'); burst=int(name!='word')
        prepared=prepare(build,DEFAULT_GCC,firmware=fw,icache_enable=enabled,dcache_enable=enabled,burst_fill=burst)
        route=(build/'route.tcl').read_text(); route=re.sub(r'-gplace_seed \d+',f'-gplace_seed {a.seed}',route); route=re.sub(r'-groute_seed \d+',f'-groute_seed {a.seed}',route)
        route=re.sub(r'-fix_hold_violation_iterations \d+',f'-fix_hold_violation_iterations {a.hold_iterations}',route)
        route=re.sub(r'-fix_hold_violation_threshold \d+',f'-fix_hold_violation_threshold {a.hold_margin_ps}',route)
        assert 0<=a.clock_hold_margin_ps<=200 and 0<=a.srb_hold_margin_ps<=1800 and 0<=a.hold_path_limit<=100000
        if (a.clock_hold_margin_ps,a.srb_hold_margin_ps,a.hold_path_limit)!=(100,200,15000):
            route=route.replace('-fix_hold_violation_in_route TRUE',f'-fix_hold_violation_in_route TRUE -fix_hold_violation_threshold_for_clk_tree {a.clock_hold_margin_ps} -fix_hold_violation_threshold_for_clock_path_cross_srb {a.srb_hold_margin_ps} -max_hold_violated_paths_num {a.hold_path_limit}')
        if a.no_cluster: route=route.replace('pnr -report_timing','pnr -report_timing -refineplacement_cluster FALSE')
        assert 0<=a.decongestion<=9
        if a.decongestion!=1: route=route.replace('pnr -report_timing',f'pnr -report_timing -plc_decongestion {a.decongestion}')
        (build/'implementation.tcl').write_text(route+'gen_bit_stream\n',encoding='ascii')
        prepared['route_seed']=a.seed; prepared['hold_fix_iterations']=a.hold_iterations
        prepared['hold_optimization']={'post_route_margin_ps':a.hold_margin_ps,'clock_tree_margin_ps':a.clock_hold_margin_ps,
                                       'clock_cross_srb_margin_ps':a.srb_hold_margin_ps,'max_paths':a.hold_path_limit}
        prepared['placement_clustering']=not a.no_cluster
        prepared['placement_decongestion']=a.decongestion
        (build/'prepared.json').write_text(json.dumps(prepared,indent=2))
        record['prepared']=prepared; manifest.write_text(json.dumps(record,indent=2))
        env=os.environ.copy(); env['PANGO_LICENSE_FILE']=license_path(None)
        print('RUN PDS '+name,flush=True)
        run=subprocess.run([str(a.pds/'bin/pds_shell.exe'),'-file','implementation.tcl','-project_name','rv32_cache_board'],cwd=build,env=env,capture_output=True,text=True,errors='replace',timeout=1800)
        output=run.stdout+run.stderr; (build/'pds_console.log').write_text(output,encoding='utf-8')
        assert run.returncode==0 and not any(x.startswith('E:') for x in output.splitlines()) and 'Generating Programming File done.' in output,output[-6000:]
        facts=audit(build,report)
        out=PROJECT/'download'; out.mkdir(exist_ok=True); target=out/('cache_selftest_25mhz.sbit' if name=='selftest' else 'coremark_'+name+'_25mhz.sbit')
        shutil.copy2(build/'generate_bitstream/board_top.sbit',target)
        fd=out/name; fd.mkdir(exist_ok=True)
        for n in ('firmware.elf','firmware.bin','firmware_rom.hex','build.json','firmware.symbols'): shutil.copy2(fw[0]/n,fd/n)
        portable=PROJECT/'pds_projects'/name; portable.mkdir(parents=True,exist_ok=True)
        for n in ('rv32_board_design.v','firmware_rom.hex','board_io_reference.fdc','timing.fdc','implementation.tcl'): shutil.copy2(build/n,portable/n)
        native=(build/'rv32_cache_board.pds').read_text(); native=re.sub(r'(_gci_state\s+\(_integer\s+)\d+',r'\g<1>0',native)
        (portable/'rv32_cache_board.pds').write_text(native,encoding='utf-8')
        record.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),prepared=prepared,audit=facts,bitstream=target.relative_to(PROJECT).as_posix(),
                      bitstream_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),bitstream_bytes=target.stat().st_size)
        manifest.write_text(json.dumps(record,indent=2)); print('CACHE_BOARD_PDS_PASS '+name,flush=True)
    except Exception as exc:
        record.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(record,indent=2)); raise
if __name__=='__main__': raise SystemExit('MEXT1: use scripts/mext_pds.py --software-isa native|software. This inherited CACHE3 entry is disabled.')
