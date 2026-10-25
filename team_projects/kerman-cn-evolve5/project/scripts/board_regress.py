"""Simulate the actual 25 MHz board firmware with its real debounce/heartbeat."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
from prepare_board import PROJECT,BOARD,prepare
from regress import run_command

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--gcc',type=Path,default=Path(r'D:\riscv\riscv64-unknown-elf-toolchain-10.2.0-2020.12.8-x86_64-w64-mingw32\bin\riscv64-unknown-elf-gcc.exe'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work'/'cache3_board_sim')
    a=p.parse_args(); build=a.build_dir.resolve()
    reports=PROJECT/'reports'/'board'; reports.mkdir(parents=True,exist_ok=True)
    latest=reports/'simulation.json'
    state={'status':'running','started_utc':datetime.now(timezone.utc).isoformat()}
    latest.write_text(json.dumps(state,indent=2),encoding='utf-8')
    try:
        prepared=prepare(build,a.gcc)
        env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
        run_command([vb/'xvlog.bat','-sv',build/'rv32_board_design.v',PROJECT/'sim'/'tb_board.sv'],build,build/'xsim_compile.log',env)
        run_command([vb/'xelab.bat','tb_board','-s','board_demo_sim','-debug','typical','-mt','4'],build,build/'xsim_elaborate.log',env)
        tcl='open_vcd {'+(reports/'board_io.vcd').as_posix()+'}\n'
        for s in ('key0_n','key1_n','uart_rx','uart_tx','led0','led1'):
            tcl+='log_vcd [get_objects /tb_board/'+s+']\n'
        tcl+='log_vcd [get_objects /tb_board/dut/soc_reset]\nrun all\nclose_vcd\nquit\n'
        (build/'wave.tcl').write_text(tcl,encoding='utf-8')
        output=run_command([vb/'xsim.bat','board_demo_sim','-onfinish','stop','-tclbatch','wave.tcl'],build,build/'xsim_run.log',env,timeout=900)
        if 'BOARD_SIM_PASS' not in output: raise RuntimeError(output[-5000:])
        state.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),
                     checks=re.findall(r'BOARD_CHECK (\S+)',output),prepared=prepared,
                     summary=(build/'board_result.txt').read_text().strip(),
                     physical_board_tested=False,electrical_signoff=False)
        for f in ('xsim_compile.log','xsim_elaborate.log','xsim_run.log','board_uart.txt','board_result.txt'):
            shutil.copy2(build/f,reports/f)
        target=reports/'firmware'; target.mkdir(exist_ok=True)
        for file in (build/'firmware'/'board_demo_O2').iterdir():
            if file.is_file() and file.suffix!='.o': shutil.copy2(file,target/file.name)
        latest.write_text(json.dumps(state,indent=2),encoding='utf-8')
        print('BOARD_REGRESSION_PASS '+state['summary'],flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc)); latest.write_text(json.dumps(state,indent=2),encoding='utf-8'); raise

if __name__=='__main__': main()
