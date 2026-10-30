from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/sim/fspi'
OUT.mkdir(parents=True,exist_ok=True)
sources=['sim/TB_fspi.v','rtl/rk_fspi/rk_fspi_adapter.v',
         'rtl/peripheral_bus.v','rtl/uart_tx.v']
subprocess.run(['iverilog','-g2012','-Wall','-s','TB_fspi','-o',str(OUT/'test.vvp'),*sources],cwd=ROOT,check=True)
r=subprocess.run(['vvp',str(OUT/'test.vvp')],cwd=ROOT,capture_output=True,text=True,timeout=120)
report=r.stdout+r.stderr
(OUT/'test.log').write_text(report,encoding='utf-8')
print(report,end='')
if r.returncode or 'PASS:' not in report or 'FATAL' in report or 'ERROR' in report:
    raise RuntimeError('FSPI behavioral regression failed')
