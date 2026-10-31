"""Fast software integration checks only; no full network inference/RTL run."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def main():
    out=ROOT/'build/board-ai/checks';out.mkdir(parents=True,exist_ok=True)
    checks={}
    def run(name,command):
        r=subprocess.run(list(map(str,command)),cwd=ROOT,capture_output=True,text=True,timeout=60)
        (out/(name+'.log')).write_text(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(name+' failed:\n'+(r.stdout+r.stderr)[-3000:])
        return r.stdout+r.stderr
    host=run('rk_clients',['make','-C',ROOT/'csrc/rk_fspi','all','test'])
    checks['rk_clients']='PASS RK model client:' in host and 'PASS: SPI-only' in host
    for name,source,extra,options in [
        ('loader','scripts/test_ai_board.c','firmware/ai_network.c',['-D_GNU_SOURCE']),
        ('input_binding','scripts/test_ai_runtime_bind.c','csrc/software/ai_runtime.c',['-DAI_DDR_BYTES=0x04000000u'])]:
        run(name+'_build',['gcc','-O2','-std=c11','-Wall','-Wextra','-Werror',*options,
            '-I',ROOT/'firmware','-I',ROOT/'csrc/software','-I',ROOT/'csrc/rk_fspi',ROOT/source,ROOT/extra,'-o',out/name])
        checks[name]='PASS' in run(name,[out/name])
    sources=['firmware/ai_network.c','firmware/ai_network.h','csrc/software/ai_runtime.c',
             'csrc/software/ai_runtime.h','csrc/rk_fspi/rk_model_cli.c','firmware/rk_spi_comm.c']
    report=dict(passed=all(checks.values()),scope='software loader/control/host and runtime input rebinding',checks=checks,
                model_math_executed=False,rtl_simulation_run=False,rk_hardware_verified=False,fpga_hardware_verified=False,
                sources={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources})
    (ROOT/'reports/preprocess/network_software.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS board-network software checks: upload/control, host clients, input binding; no network math or RTL run')


if __name__=='__main__':main()
