from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/sim/fspi'
OUT.mkdir(parents=True,exist_ok=True)
base=(ROOT/'sim/TB_fspi.v').read_text(encoding='utf-8-sig')
mode0=base.replace('sck=1,cs=1','sck=0,cs=1').replace('begin sck=1;cs=0;#7;', 'begin sck=0;cs=0;#7;')
mode0=mode0.replace('sck=0;drive=1;dq=v;#10;sck=1;#10;', 'drive=1;dq=v;#10;sck=1;#10;sck=0;')
mode0=mode0.replace('drive=0;sck=0;#10;sck=1;#1;v[7:4]=bus;#9;', 'drive=0;#10;sck=1;#1;v[7:4]=bus;#9;sck=0;')
mode0=mode0.replace('sck=0;#10;sck=1;#1;v[3:0]=bus;#9;', '#10;sck=1;#1;v[3:0]=bus;#9;sck=0;').replace('mode3','mode0')
for name,text in [('mode3_25m',base),('mode3_async',base.replace('always #20','always #18.5')),('mode0_25m',mode0)]:
    tb=OUT/(name+'.v');tb.write_text(text)
    binary=OUT/(name+'.vvp')
    sources=[str(tb),'rtl/rk_fspi/rk_fspi_adapter.v','rtl/peripheral_bus.v','rtl/uart_tx.v']
    subprocess.run(['iverilog','-g2012','-s','TB_fspi','-o',str(binary),*sources],cwd=ROOT,check=True)
    r=subprocess.run(['vvp',str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=120)
    report=r.stdout+r.stderr
    (OUT/(name+'.log')).write_text(report,encoding='utf-8')
    print(name+': '+report,end='')
    if r.returncode or 'PASS:' not in report or 'FATAL' in report or 'ERROR' in report:
        raise RuntimeError('FSPI behavioral regression failed')
