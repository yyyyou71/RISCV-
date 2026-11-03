"""Short real-firmware SPI tail/COMMIT check, with explicit prefix acceleration.

Does not simulate the 13MB prefix, physical DDR PHY or routed delays.
"""
from pathlib import Path
import hashlib,json,subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/spi-model-commit'
OUT.mkdir(parents=True,exist_ok=True)
def run(args,timeout=90):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,capture_output=True,text=True,timeout=timeout)
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    return p.stdout+p.stderr

manifest=json.loads((ROOT/'firmware/manifest.json').read_text())
assert manifest['application']=='spi_image'
for name,value in manifest['sources'].items():
    assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==value,name
for kind in ['rom','ram']:
    assert hashlib.sha256((ROOT/f'firmware/acore_dual_{kind}.hex').read_bytes()).hexdigest()==manifest[kind+'_sha256']
elf=ROOT/'build/firmware/acore-dual-spi_image-performance-2700/spi_image.elf'
assert hashlib.sha256(elf.read_bytes()).hexdigest()==manifest['elf_sha256']
symbols={};owner=''
for line in run(['riscv64-unknown-elf-readelf','-sW',elf]).splitlines():
    fields=line.split()
    if len(fields)<8:continue
    if fields[3]=='FILE':owner=fields[7]
    if owner=='ai_network.c' and fields[3]=='OBJECT':symbols[fields[7]]=int(fields[1],16)
assert all(name in symbols for name in ['received','hash']),symbols
model=(ROOT/'build/board-ai/board_model_addrprobe.bin').read_bytes()
tail=len(model)-(len(model)%224 or 224)
value=2166136261
prefix=0
for index,byte in enumerate(model):
    if index==tail:prefix=value
    value=((value^byte)*16777619)&0xffffffff
fixture='''initial begin
 #1;
'''
for address in [0x5000,0x10000]:
    for offset in range(0,64,16):
        word=int.from_bytes(model[address+offset:address+offset+16],'little')
        fixture+=f" ring.u_ddr3.store_word(28'h{(0x4000000+address+offset)//2:x},128'h{word:032x},16'hffff);\n"
fixture+='end\ninteger i;\ninitial begin\n for(i=0;i<256;i=i+1)request[i]=0;\n repeat(6)@(negedge clk);rst_n=1;repeat(12)@(negedge clk);rst_n=0;repeat(12)@(negedge clk);rst_n=1;wait(ready);\n'
fixture+=f" put32(16,123);put32(20,{len(model)});put32(24,32'h{value:08x});put32(28,32'h{value:08x});\n"
fixture+=" exchange(9,1,16);if(get32(16)!==0)$fatal(1,\"BEGIN rejected\");\n @(negedge clk);\n"
fixture+=f" poke32(32'h{symbols['received']:x},{tail});poke32(32'h{symbols['hash']:x},32'h{prefix:08x});\n"
fixture+=f' put32(16,123);put32(20,{tail});\n'
for i,byte in enumerate(model[tail:]):fixture+=f" request[{24+i}]=8'h{byte:02x};\n"
fixture+=f" exchange(10,2,{8+len(model)-tail});if(get32(16)!==0||get32(44)!=={len(model)})$fatal(1,\"CHUNK rejected\");\n"
fixture+=' put32(16,123);exchange(11,3,4);\n'
fixture+=' if(get32(16)!==0||get32(28)!==2)$fatal(1,"COMMIT rejected status=%h state=%h",get32(16),get32(28));\n'
fixture+=f" if(aw_count!=1||ar_count!=3||reads[0]!==28'h{(0x4000000+tail)//2:x}||reads[1]!==28'h2008000||reads[2]!==28'h2002800)$fatal(1,\"missing/wrong native requests aw=%0d ar=%0d\",aw_count,ar_count);\n"
fixture+=' $display("PASS real firmware SPI CHUNK/COMMIT: tail window replaced by two distinct headers; shared DDR native requests checked");$finish;\nend\n'
(OUT/'model_commit_fixture.vh').write_text(fixture)
results=[]
for dual in [1]:
    binary=OUT/f'cpu-{dual}.vvp'
    run(['iverilog','-g2012','-s','TB_spi_model_commit','-P',f'TB_spi_model_commit.ENABLE_DUAL={dual}',
         '-I',OUT,'-y','sim/models','-y','rtl','-y','rtl/rk_fspi','-y','rtl/video',
         '-DPROG_FILE="firmware/acore_dual_rom.hex"','-DDATA_FILE="firmware/acore_dual_ram_bytes.hex"',
         '-o',binary,'sim/ai/TB_spi_model_commit.v','sim/ddr3/ddr3.sv'])
    log=run(['vvp',binary],timeout=90)
    (OUT/f'cpu-{dual}.log').write_text(log)
    print(f'CPU dual={dual}\n{log}',flush=True)
    results.append({'dual':dual,'passed':True,'log':str((OUT/f'cpu-{dual}.log').relative_to(ROOT))})
(ROOT/'reports/spi_image/real_firmware_commit.json').write_text(json.dumps(dict(passed=True,
    prefix_fast_forwarded_bytes=tail,spi_uploaded_bytes=len(model)-tail,physical_phy_verified=False,
    routed_delays_simulated=False,cases=results,firmware_elf_sha256=manifest['elf_sha256']),indent=2)+'\n')
