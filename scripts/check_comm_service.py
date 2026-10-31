from pathlib import Path
import subprocess,json
root=Path(__file__).resolve().parents[1]
out=root/'build/comm_service';out.mkdir(parents=True,exist_ok=True)
exclude={'ROM_core.v','memory_core.v','multiplier_core.v','acore_fetch_memory.v','MuxKeyInternal.v','multiply_adder.v','multiply_adder_w8a16.v','video_async_fifo.v'}
rtl=[p for p in sorted((root/'rtl').glob('*.v')) if p.name not in exclude]
for directory in ['sim/models','rtl/rk_iic','rtl/rk_fspi','board']:rtl+=list((root/directory).glob('*.v'))
cmd=['iverilog','-g2012','-s','TB_comm_service','-DNO_WAVES','-DPROG_FILE="firmware/comm_service/acore_dual_rom.hex"','-DDATA_FILE="firmware/comm_service/acore_dual_ram_bytes.hex"','-o',str(out/'app.vvp'),str(root/'sim/TB_comm_service.v'),*map(str,rtl)]
subprocess.run(cmd,cwd=root,check=True)
r=subprocess.run(['vvp',str(out/'app.vvp')],cwd=root,capture_output=True,text=True,timeout=180)
text=r.stdout+r.stderr;(out/'application.log').write_text(text);print(text)
assert r.returncode==0 and 'PASS:' in text
(out/'result.json').write_text(json.dumps({'application_regression':'passed','physical_iic_frontend':'covered separately','hardware_test':'not_run','ip_initialization_update':'user_owned'},indent=2))
