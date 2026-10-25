"""Implement MEXT1 in an isolated directory; publish only after full sign-off."""
import argparse,hashlib,json,os,re,shutil,subprocess
from datetime import datetime,timezone
from pathlib import Path
from regress import PROJECT
from build_coremark import build_coremark,DEFAULT_GCC
from prepare_board import prepare,BOARD
from run_pds import license_path,signoff_errors
from audit_pds import audit

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--software-isa',choices=('native','software'),default='native')
    p.add_argument('--seed',type=int,default=6)
    p.add_argument('--hold-iterations',type=int,default=10)
    p.add_argument('--hold-margin-ps',type=int,default=50)
    p.add_argument('--no-cluster',action='store_true')
    p.add_argument('--cluster',action='store_false',dest='no_cluster')
    p.set_defaults(no_cluster=True)
    p.add_argument('--pds',type=Path,default=Path(r'C:\pango\PDS_2022.2-SP6.1'))
    p.add_argument('--build-dir',type=Path)
    p.add_argument('--reports',type=Path)
    a=p.parse_args(); name=a.software_isa
    build=(a.build_dir or PROJECT.parents[1]/'work'/f'evolve5_pds_{name}').resolve()
    report=a.reports or PROJECT/'reports/pds'/name; report.mkdir(parents=True,exist_ok=True)
    record={'status':'running','variant':name,'hardware_tested':False,'started_utc':datetime.now(timezone.utc).isoformat()}
    manifest=report/'build.json'; manifest.write_text(json.dumps(record))
    try:
        assert not signoff_errors(json.loads((BOARD/'electrical_review.json').read_text()))
        fw=build_coremark(build,DEFAULT_GCC,2048,name)
        prepared=prepare(build,DEFAULT_GCC,firmware=fw,m_enable=1)
        route=(build/'route.tcl').read_text()
        route=re.sub(r'-gplace_seed \d+',f'-gplace_seed {a.seed}',route)
        route=re.sub(r'-groute_seed \d+',f'-groute_seed {a.seed}',route)
        route=re.sub(r'-fix_hold_violation_iterations \d+',f'-fix_hold_violation_iterations {a.hold_iterations}',route)
        assert 0<=a.hold_margin_ps<=200
        route=re.sub(r'-fix_hold_violation_threshold \d+',f'-fix_hold_violation_threshold {a.hold_margin_ps}',route)
        if a.no_cluster: route=route.replace('pnr -report_timing','pnr -report_timing -refineplacement_cluster FALSE')
        (build/'implementation.tcl').write_text(route+'gen_bit_stream\n',encoding='ascii')
        prepared.update(route_seed=a.seed,hold_fix_iterations=a.hold_iterations,hold_margin_ps=a.hold_margin_ps,placement_clustering=not a.no_cluster)
        (build/'prepared.json').write_text(json.dumps(prepared,indent=2))
        record['prepared']=prepared; manifest.write_text(json.dumps(record,indent=2))
        env=os.environ.copy(); env['PANGO_LICENSE_FILE']=license_path(None)
        print('RUN PDS MEXT1 '+name,flush=True)
        run=subprocess.run([str(a.pds/'bin/pds_shell.exe'),'-file','implementation.tcl','-project_name','rv32im_front1'],cwd=build,env=env,capture_output=True,text=True,errors='replace',timeout=2400)
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
        target=out/f'coremark_front1_{name}_25mhz.sbit'
        shutil.copy2(build/'generate_bitstream/board_top.sbit',target)
        fd=out/name; fd.mkdir(exist_ok=True)
        for n in ('firmware.elf','firmware.bin','firmware_rom.hex','build.json','firmware.symbols','firmware.dis'): shutil.copy2(fw[0]/n,fd/n)
        portable=PROJECT/'pds_projects'/name; portable.mkdir(parents=True,exist_ok=True)
        for n in ('rv32_board_design.v','firmware_rom.hex','board_io_reference.fdc','timing.fdc','implementation.tcl'): shutil.copy2(build/n,portable/n)
        native=(build/'rv32im_front1.pds').read_text()
        native=re.sub(r'(_gci_state\s+\(_integer\s+)\d+',r'\g<1>0',native)
        (portable/'rv32im_front1.pds').write_text(native,encoding='utf-8')
        record.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),audit=facts,
                      bitstream=target.relative_to(PROJECT).as_posix(),bitstream_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),bitstream_bytes=target.stat().st_size)
        manifest.write_text(json.dumps(record,indent=2)); print(f'MEXT1_PDS_PASS {name} DSP={len(dsps)}',flush=True)
    except Exception as exc:
        for path in ('pds_console.log','place_route/board_top.rtr','place_route/board_top.prr','synthesize/board_top.snr'):
            source=build/path
            if source.exists(): shutil.copy2(source,report/source.name)
        record.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(record,indent=2)); raise
if __name__=='__main__': main()
