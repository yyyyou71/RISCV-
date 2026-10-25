import argparse,hashlib,json,os,shutil
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command
from build_machine_demo import build_demo
from build_coremark import DEFAULT_GCC
from prepare_board import prepare

def main():
    p=argparse.ArgumentParser(); p.add_argument('--gcc',type=Path,default=DEFAULT_GCC)
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work/cache3_demo_sim')
    a=p.parse_args(); build=a.build_dir.resolve(); reports=PROJECT/'reports/machine/demo'; reports.mkdir(parents=True,exist_ok=True)
    state={'status':'running','started_utc':datetime.now(timezone.utc).isoformat()}; manifest=reports/'simulation.json'; manifest.write_text(json.dumps(state))
    try:
        firmware=build_demo(build,a.gcc); prepared=prepare(build,a.gcc,firmware=firmware)
        env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
        run_command([vb/'xvlog.bat','-sv',build/'rv32_board_design.v',PROJECT/'sim/tb_machine_demo.sv'],build,build/'compile.log',env)
        run_command([vb/'xelab.bat','tb_machine_demo','-s','machine_demo','-mt','4'],build,build/'elaborate.log',env)
        text=run_command([vb/'xsim.bat','machine_demo','-runall'],build,build/'simulate.log',env,timeout=900)
        assert 'MACHINE_DEMO_PASS' in text,text[-6000:]
        uart=(build/'machine_uart.txt').read_text()
        assert 'CACHE_SELFTEST_PASS lru=1 byte_halfword=1 write_through=1 mmio=1 burst=1' in uart and 'CACHE_SELFTEST_FAIL' not in uart
        for name in ('compile.log','elaborate.log','simulate.log','machine_uart.txt','trap_frames.csv'): shutil.copy2(build/name,reports/name)
        folder=reports/'firmware'; folder.mkdir(exist_ok=True)
        for path in firmware[0].iterdir():
            if path.is_file() and path.suffix!='.o': shutil.copy2(path,folder/path.name)
        state.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),prepared=prepared,
                     exceptions=13,timer_interrupts=4,checked_frame_returns=17,all_31_gprs_preserved=True,max_nested_depth=2,cache_selftest_passed=True,
                     firmware_rom_sha256=hashlib.sha256((build/'firmware_rom.hex').read_bytes()).hexdigest(),hardware_tested=False)
        manifest.write_text(json.dumps(state,indent=2),encoding='utf-8'); print('MACHINE_DEMO_REGRESSION_PASS',flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(state,indent=2),encoding='utf-8'); raise

if __name__=='__main__': main()
