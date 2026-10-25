"""Synthesis-only resource comparison; never publishes a bitstream or timing pass."""
import argparse,hashlib,json,os,re,shutil
from regress import PROJECT,run_command
from pathlib import Path
from prepare_board import prepare
from build_coremark import DEFAULT_GCC
from run_pds import license_path
from front_configs import CONFIGS
p=argparse.ArgumentParser();p.add_argument('--config',choices=CONFIGS,required=True);a=p.parse_args()
build=PROJECT.parents[1]/'work'/('evolve5_syn_'+a.config);report=PROJECT/'reports/synthesis'/a.config;report.mkdir(parents=True,exist_ok=True)
state={'status':'running','timing_signoff':False,'hardware_tested':False}
try:
    folder=PROJECT/'reference/frozen_front1';fw=(folder,json.loads((folder/'build.json').read_text()))
    prepared=prepare(build,DEFAULT_GCC,firmware=fw,**CONFIGS[a.config])
    env=os.environ.copy();env['PANGO_LICENSE_FILE']=license_path(None)
    out=run_command([Path(r'C:\pango\PDS_2022.2-SP6.1\bin\pds_shell.exe'),'-file','synthesis.tcl','-project_name','front_resource'],build,build/'synthesis_console.log',env)
    snr=(build/'synthesize/board_top.snr').read_text()
    def field(pattern):return float(re.search(pattern,snr)[1])
    state.update(status='passed_synthesis_only',config=a.config,prepared=prepared,
                 luts=int(field(r'Total LUTs: (\d+)')),registers=int(field(r'Total Registers: (\d+)')),
                 latches=int(field(r'Total Latches: (\d+)')),dsp=int(field(r'Total APMs = ([\d.]+)')),drm=int(field(r'Total DRM = ([\d.]+)')))
    assert state['latches']==0 and state['dsp']==4 and state['drm']==16
    for src in ('synthesize/board_top.snr','synthesize/apm_drm_lutram_utilization.log','synthesis_console.log'):shutil.copy2(build/src,report/Path(src).name)
    print('FRONT_SYNTHESIS '+a.config+' LUT='+str(state['luts'])+' FF='+str(state['registers']),flush=True)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:(report/'result.json').write_text(json.dumps(state,indent=2))
