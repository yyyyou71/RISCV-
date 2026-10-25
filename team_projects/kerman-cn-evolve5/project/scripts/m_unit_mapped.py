"""Replay arithmetic/kill/backpressure vectors through PDS-mapped DSP primitives.

Uses the locally installed licensed PDS simulation models in place; no models
are copied into the deliverable. This is functional synthesis simulation, no SDF.
"""
import hashlib,json,os,re,shutil,subprocess
from pathlib import Path
from regress import PROJECT,run_command
from run_pds import license_path
build=PROJECT.parents[1]/'work/evolve5_mapped_unit'; build.mkdir(exist_ok=True)
report=PROJECT/'reports/m_mapped'; report.mkdir(parents=True,exist_ok=True)
state={'status':'running','hardware_tested':False,'sdf_timing_simulation':False}
try:
    pds=Path(r'C:\pango\PDS_2022.2-SP6.1'); env=os.environ.copy(); env['PANGO_LICENSE_FILE']=license_path(None)
    (build/'rv32_muldiv.v').write_text((PROJECT/'rtl/rv32_muldiv.v').read_text().replace('parameter FAST_MUL=0','parameter FAST_MUL=1'),encoding='utf-8')
    (build/'synth.tcl').write_text('set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484\nadd_design -verilog "rv32_muldiv.v"\ncompile -top_module rv32_muldiv\nsynthesize -ads -frequency 25\n')
    run_command([pds/'bin/pds_shell.exe','-file','synth.tcl','-project_name','mdu'],build,build/'pds.log',env)
    net=build/'synthesize/rv32_muldiv_syn.vm'; text=net.read_text()
    library=pds/'arch/vendor/pango/verilog/simulation'
    primitives=set(re.findall(r'\b((?:GTP|INT)_[A-Z0-9_]+)\b',text))|{'GTP_GRS'}
    pending=list(primitives)
    while pending:
        name=pending.pop(); source=library/(name+'.v'); assert source.exists(),name
        for dependency in re.findall(r'\b((?:GTP|INT)_[A-Z0-9_]+)\b',source.read_text()):
            if dependency not in primitives and (library/(dependency+'.v')).exists():
                primitives.add(dependency); pending.append(dependency)
    dsp_count=len(re.findall(r'^\s*GTP_APM_E2\b',text,re.M)); assert dsp_count>0
    models=[library/(n+'.v') for n in sorted(primitives)]
    assert all(x.exists() for x in models)
    tb=(PROJECT/'sim/tb_muldiv.sv').read_text().replace('parameter FAST=0;','parameter FAST=1;').replace('reg rst=1,kill=0,req=0,take=0;',"reg rst=1,kill=0,req=0,take=0;\n    GTP_GRS GRS_INST(.GRS_N(!rst));")
    (build/'tb_muldiv.sv').write_text(tb)
    shutil.copy2(PROJECT/'reports/m_unit/m_vectors.txt',build/'m_vectors.txt')
    env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    run_command([vb/'xvlog.bat','-sv',*models,net,build/'tb_muldiv.sv'],build,build/'compile.log',env)
    run_command([vb/'xelab.bat','tb_muldiv','-s','mapped','-mt','4'],build,build/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','mapped','-runall'],build,build/'simulate.log',env,timeout=900)
    assert 'MULDIV_UNIT_PASS vectors=17952 cancellation_cases=48' in out and 'ERROR:' not in out
    state.update(status='passed',vectors=17952,cancellation_cases=48,dsp_count=dsp_count,
                 models={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in models},
                 rtl_sha256=hashlib.sha256((build/'rv32_muldiv.v').read_bytes()).hexdigest())
    shutil.copy2(net,report/net.name)
    for name in ('rv32_muldiv.snr','apm_drm_lutram_utilization.log'): shutil.copy2(build/'synthesize'/name,report/name)
    print('MAPPED_MULDIV_PASS DSP='+str(dsp_count),flush=True)
except Exception as exc: state.update(status='failed',error=str(exc)); raise
finally:
    for f in build.glob('*.log'): shutil.copy2(f,report/f.name)
    (report/'result.json').write_text(json.dumps(state,indent=2))
