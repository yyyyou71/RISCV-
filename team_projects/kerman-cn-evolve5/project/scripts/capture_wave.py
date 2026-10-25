"""Capture an actual CPU simulation waveform from an already-passed build."""
import argparse
from pathlib import Path
import os
import shutil
from regress import PROJECT, run_command


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work'/'cache3_cpu')
    p.add_argument('--case',default='load_use_and_store__i0d3')
    a = p.parse_args()
    build = a.build_dir.resolve()
    line = next(x for x in (build/'manifest.txt').read_text().splitlines() if x.split()[0] == a.case)
    (build/'wave_manifest.txt').write_text(line+'\n',encoding='ascii')
    (build/'wave.args').write_text('--testplusarg MANIFEST=wave_manifest.txt\n--testplusarg RESULTS=wave_results.csv\n--testplusarg TRACE=wave_retire.log\n',encoding='ascii')
    wave = PROJECT/'reports'/'pipeline_example.vcd'
    tcl = 'open_vcd {'+wave.as_posix()+'}\n'
    tcl += 'log_vcd [get_objects /tb_core/clk]\nlog_vcd [get_objects /tb_core/rst]\n'
    tcl += 'log_vcd [get_objects -r /tb_core/dut/*]\nrun all\nclose_vcd\nquit\n'
    (build/'capture_wave.tcl').write_text(tcl,encoding='utf-8')
    env = os.environ.copy(); env['PROCESSOR_ARCHITECTURE'] = 'AMD64'
    output = run_command([a.vivado/'bin'/'xsim.bat','rv32_regression','-f','wave.args',
                          '-onfinish','stop','-tclbatch','capture_wave.tcl'],build,build/'wave.log',env)
    if 'REGRESSION_PASS cases=1' not in output or not wave.is_file() or wave.stat().st_size < 100:
        raise RuntimeError('Waveform replay did not pass')
    shutil.copy2(build/'wave_results.csv',PROJECT/'reports'/'wave_case.csv')
    shutil.copy2(build/'wave_retire.log',PROJECT/'reports'/'wave_retire.log')
    shutil.copy2(build/'wave.log',PROJECT/'reports'/'wave.log')
    print('WAVE_PASS '+str(wave),flush=True)


if __name__ == '__main__': main()
