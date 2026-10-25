"""Implement EVOLVE5 in an isolated directory; publish only after full sign-off."""
import argparse,hashlib,json,os,re,shutil,subprocess
from datetime import datetime,timezone
from pathlib import Path
from regress import PROJECT
from build_coremark import build_coremark,DEFAULT_GCC
from prepare_board import prepare,BOARD
from run_pds import license_path,signoff_errors
from audit_pds import audit
from front_configs import CONFIGS

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--firmware-dir',type=Path)
    p.add_argument('--artifact-label')
    p.add_argument('--software-isa',choices=('native','software'),default='native')
    p.add_argument('--config',choices=CONFIGS,default='mul_pair_combo')
    p.add_argument('--seed',type=int,default=1)
    p.add_argument('--hold-iterations',type=int,default=15)
    p.add_argument('--hold-margin-ps',type=int,default=100)
    p.add_argument('--clock-hold-margin-ps',type=int,default=200)
    p.add_argument('--srb-hold-margin-ps',type=int,default=400)
    p.add_argument('--hold-path-limit',type=int,default=100000)
    p.add_argument('--decongestion',type=int,default=3)
    p.add_argument('--no-cluster',action='store_true')
    p.add_argument('--cluster',action='store_false',dest='no_cluster')
    p.set_defaults(no_cluster=True)
    p.add_argument('--pds',type=Path,default=Path(r'C:\pango\PDS_2022.2-SP6.1'))
    p.add_argument('--build-dir',type=Path)
    p.add_argument('--reports',type=Path)
    a=p.parse_args(); name=a.config+('_software' if a.software_isa=='software' else '')
    build=(a.build_dir or PROJECT.parents[1]/'work'/f'evolve5_pds_{name}').resolve()
    report=a.reports or PROJECT/'reports/pds'/name; report.mkdir(parents=True,exist_ok=True)
    record={'status':'running','variant':name,'config':a.config,'hardware_tested':False,'started_utc':datetime.now(timezone.utc).isoformat()}
    manifest=report/'build.json'; manifest.write_text(json.dumps(record))
    try:
        assert not signoff_errors(json.loads((BOARD/'electrical_review.json').read_text()))
        fw=(a.firmware_dir,json.loads((a.firmware_dir/'build.json').read_text(encoding='utf-8'))) if a.firmware_dir else build_coremark(build,DEFAULT_GCC,2048,a.software_isa)
        prepared=prepare(build,DEFAULT_GCC,firmware=fw,m_enable=1,**CONFIGS[a.config])
        route=(build/'route.tcl').read_text()
        route=re.sub(r'-gplace_seed \d+',f'-gplace_seed {a.seed}',route)
        route=re.sub(r'-groute_seed \d+',f'-groute_seed {a.seed}',route)
        route=re.sub(r'-fix_hold_violation_iterations \d+',f'-fix_hold_violation_iterations {a.hold_iterations}',route)
        assert 0<=a.hold_margin_ps<=200
        route=re.sub(r'-fix_hold_violation_threshold \d+',f'-fix_hold_violation_threshold {a.hold_margin_ps}',route)
        if a.no_cluster: route=route.replace('pnr -report_timing','pnr -report_timing -refineplacement_cluster FALSE')
        assert 0<=a.clock_hold_margin_ps<=200 and 0<=a.srb_hold_margin_ps<=1800 and 0<=a.hold_path_limit<=100000 and 0<=a.decongestion<=9
        if (a.clock_hold_margin_ps,a.srb_hold_margin_ps,a.hold_path_limit)!=(100,200,15000):
            route=route.replace('-fix_hold_violation_in_route TRUE',f'-fix_hold_violation_in_route TRUE -fix_hold_violation_threshold_for_clk_tree {a.clock_hold_margin_ps} -fix_hold_violation_threshold_for_clock_path_cross_srb {a.srb_hold_margin_ps} -max_hold_violated_paths_num {a.hold_path_limit}')
        if a.decongestion!=1: route=route.replace('pnr -report_timing',f'pnr -report_timing -plc_decongestion {a.decongestion}')
        (build/'implementation.tcl').write_text(route+'gen_bit_stream\n',encoding='ascii')
        prepared.update(route_seed=a.seed,hold_fix_iterations=a.hold_iterations,hold_margin_ps=a.hold_margin_ps,placement_clustering=not a.no_cluster)
        prepared['hold_optimization']={'clock_tree_margin_ps':a.clock_hold_margin_ps,'clock_cross_srb_margin_ps':a.srb_hold_margin_ps,'max_paths':a.hold_path_limit,'decongestion':a.decongestion}
        (build/'prepared.json').write_text(json.dumps(prepared,indent=2))
        record['prepared']=prepared; manifest.write_text(json.dumps(record,indent=2))
        env=os.environ.copy(); env['PANGO_LICENSE_FILE']=license_path(None)
        print('RUN PDS EVOLVE5 '+name,flush=True)
        run=subprocess.run([str(a.pds/'bin/pds_shell.exe'),'-file','implementation.tcl','-project_name','rv32im_evolve5'],cwd=build,env=env,capture_output=True,text=True,errors='replace',timeout=2400)
        output=run.stdout+run.stderr; (build/'pds_console.log').write_text(output,encoding='utf-8')
        assert run.returncode==0 and not any(x.startswith('E:') for x in output.splitlines()) and 'Generating Programming File done.' in output,output[-6000:]
        facts=audit(build,report)
        net=(build/'synthesize/board_top_syn.vm').read_text()
        dsps=re.findall(r'GTP_APM_E2\s*(?:/\*.*?\*/)?\s*#\((.*?)\)\s+(\S+)\s*\((.*?)\);',net,re.S)
        assert dsps,'Registered multiply was not mapped to Logos2 DSP blocks'
        facts['dsp_primitive']='GTP_APM_E2'; facts['dsp_count']=len(dsps)
        facts['dsp_instances']=[{'name':n,'parameters':param,'ports':ports} for param,n,ports in dsps]
        facts['m_isa']='RV32IM_Zicsr'; facts['divider']='32-step restoring RTL, no vendor divider IP'
        (report/'audit.json').write_text(json.dumps(facts,indent=2))
        shutil.copy2(build/'synthesize/board_top_syn.vm',report/'board_top_syn.vm')
        out=PROJECT/'download'; out.mkdir(exist_ok=True)
        label=a.artifact_label or name
        target=out/f'coremark_evolve5_{label}_25mhz.sbit'
        shutil.copy2(build/'generate_bitstream/board_top.sbit',target)
        fd=out/label; fd.mkdir(exist_ok=True)
        for n in ('firmware.elf','firmware.bin','firmware_rom.hex','build.json','firmware.symbols','firmware.dis'): shutil.copy2(fw[0]/n,fd/n)
        portable=PROJECT/'pds_projects'/label; portable.mkdir(parents=True,exist_ok=True)
        for n in ('rv32_board_design.v','firmware_rom.hex','board_io_reference.fdc','timing.fdc','implementation.tcl'): shutil.copy2(build/n,portable/n)
        native=(build/'rv32im_evolve5.pds').read_text()
        native=re.sub(r'(_gci_state\s+\(_integer\s+)\d+',r'\g<1>0',native)
        (portable/'rv32im_evolve5.pds').write_text(native,encoding='utf-8')
        record.update(artifact_label=label,status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),audit=facts,
                      bitstream=target.relative_to(PROJECT).as_posix(),bitstream_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),bitstream_bytes=target.stat().st_size)
        manifest.write_text(json.dumps(record,indent=2)); print(f'EVOLVE5_PDS_PASS {name} DSP={len(dsps)}',flush=True)
    except Exception as exc:
        for path in ('pds_console.log','place_route/board_top.rtr','place_route/board_top.prr','synthesize/board_top.snr'):
            source=build/path
            if source.exists(): shutil.copy2(source,report/source.name)
        record.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(record,indent=2)); raise
if __name__=='__main__': main()
