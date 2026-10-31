"""Check merged FSPI/video address isolation and IIC using existing firmware images."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
import os
os.chdir(root)
out=root/'build/fspi-integration'
out.mkdir(parents=True,exist_ok=True)
excluded={'ROM_core.v','memory_core.v','multiplier_core.v','acore_fetch_memory.v','MuxKeyInternal.v','multiply_adder.v','multiply_adder_w8a16.v','video_async_fifo.v'}
rtl=[p for p in sorted((root/'rtl').glob('*.v')) if p.name not in excluded]
rtl+=list((root/'sim/models').glob('*.v'))+list((root/'rtl/rk_iic').glob('*.v'))+list((root/'rtl/rk_fspi').glob('*.v'))+list((root/'board').glob('*.v'))
def run(name,tb,defines=()):
    binary=out/(name+'.vvp')
    subprocess.run(['iverilog','-g2012','-s',name,'-DNO_WAVES',*defines,'-o',str(binary),str(tb),*map(str,rtl)],check=True)
    r=subprocess.run(['vvp',str(binary)],capture_output=True,text=True,timeout=180)
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode==0 and 'PASS' in r.stdout and 'FATAL' not in r.stdout,r.stdout+r.stderr
    print(r.stdout.strip(),flush=True)
s=(root/'sim/TB_fspi.v').read_text().replace('TB_fspi','TB_fspi_video')
s=s.replace('.ENABLE_FSPI(1)', '.ENABLE_FSPI(1),.ENABLE_VIDEO(1),.ENABLE_DDR(1)')
s=s.replace("32'h303","32'h307")
# Verify writes to the video aperture cannot change the FSPI index.
# RX and TX now use independent buffers, so DATA write/read is not loopback.
s=s.replace("check(32'h3071c,32'hffffffff,32'h46535032);",
    "check(32'h3071c,32'hffffffff,32'h46535032);"
    "wr(32'h30700,7);wr(32'h30300,0);wr(32'h30304,255);"
    "check(32'h30700,2047,7);wr(32'h30700,0);")
p=out/'TB_fspi_video.v';p.write_text(s)
defines=['-DPROG_FILE="firmware/rom.hex"','-DDATA_FILE="firmware/ram_bytes.hex"']
run('TB_fspi_video',p,defines)
run('TB_rk_cpu_bus',root/'sim/TB_rk_cpu_bus.v',defines)
run('TB_cpu_iic',root/'sim/TB_cpu_iic.v',['-DPROG_FILE="firmware/iic_service/rom.hex"','-DDATA_FILE="firmware/iic_service/ram_bytes.hex"'])
