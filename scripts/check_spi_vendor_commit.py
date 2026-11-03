"""Real CPU/firmware/SPI/window/shared arbiter with the official DDR PHY.

Directed CHUNK/COMMIT integration, not the full 13MB upload. Headers are seeded
through native writes before CPU reset release. Only the upload prefix bookkeeping
is fast-forwarded, exactly as declared in the earlier short behavioral-DDR test.
Runs in a separate ModelSim work library; existing checkpoints are left intact.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,subprocess,winreg

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/spi-vendor-commit';OUT.mkdir(parents=True,exist_ok=True)
MS=Path('C:/diskE/modelsim/win64')
base=json.loads((ROOT/'reports/spi_image/vendor_ddr.json').read_text())
assert base['passed'] and base['physical_vendor_model']
for name,value in base['vendor_model_sources'].items():
    # The previous bench is intentionally extended, never recompiled in its old library.
    if name.endswith('TB_vendor_ddr_retention.v'):continue
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==value,name
if not (OUT/'work').exists():shutil.copytree(ROOT/'build/vendor-ddr/work',OUT/'work')
model=(ROOT/'build/board-ai/board_model_addrprobe.bin').read_bytes()
# Source names and firmware are the same as the already verified real-firmware test.
manifest=json.loads((ROOT/'firmware/manifest.json').read_text())
assert manifest['elf_sha256']==json.loads((ROOT/'reports/spi_image/real_firmware_commit.json').read_text())['firmware_elf_sha256']
for name,value in manifest['sources'].items():assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==value,name
native={
 'awaddr':28,'araddr':28,'awuser_ap':1,'aruser_ap':1,
 'awuser_id':4,'aruser_id':4,'awlen':4,'arlen':4,'awvalid':1,'arvalid':1,
 'wdata':128,'wstrb':16,
}
returns={'awready':1,'arready':1,'wready':1,'wusero_id':4,'wusero_last':1,'rdata':128,'rid':4,'rlast':1,'rvalid':1}
seed='''reg preload_done=0;
reg seed_valid=0,seed_wr_valid=0;
reg [31:0] seed_address=0,seed_length=0;
reg [127:0] seed_data=0;
wire seed_ready,seed_wr_ready,seed_finished,seed_error;
'''
for n,w in native.items():seed+=f'wire [{w-1}:0] p_{n};\n'
seed+='ddr_block_transfer seed_transfer(\n'
seed+=' .core_clk(core_clk),.rst_n(rst_n),.ddr_init_done(ready),.cmd_valid(seed_valid),.cmd_ready(seed_ready),\n'
seed+=' .cmd_write(1\'b1),.cmd_addr(seed_address),.cmd_len(seed_length),.clear_status(1\'b0),\n'
seed+=' .done(seed_finished),.error(seed_error),.wr_valid(seed_wr_valid),.wr_ready(seed_wr_ready),.wr_data(seed_data),.rd_ready(1\'b1),\n'
seed+=',\n'.join(' .axi_'+n+'(p_'+n+')' for n in native)+',\n'
seed+=',\n'.join(' .axi_'+n+'(axi_'+n+')' for n in returns)+');\n'
seed+='''reg [127:0] seed_words[0:63];
task seed_write(input [31:0] address,input integer length,input integer first);
integer k;begin
 @(negedge core_clk);while(!seed_ready)@(negedge core_clk);
 seed_address=address;seed_length=length;seed_valid=1;
 @(negedge core_clk);seed_valid=0;
 for(k=0;k<length/16;k=k+1)begin
  seed_data=seed_words[first+k];seed_wr_valid=1;
  while(!seed_wr_ready)@(negedge core_clk);
  @(negedge core_clk);
 end
 seed_wr_valid=0;while(!seed_finished&&!seed_error)@(negedge core_clk);
 if(seed_error)$fatal(1,"official DDR seed write failed");
end endtask
initial begin
'''
plans=[(0x10000,64),(0x5000,64),(0xc10000,224),(0xc05000,224)]
for index,(a,n) in enumerate(plans):
    for o in range(0,n,16):seed+=f"seed_words[{index*16+o//16}]=128'h{int.from_bytes(model[a+o:a+o+16],'little'):032x};\n"
seed+='wait(rst_n);wait(ready);\n'
for index,(a,n) in enumerate(plans):seed+=f"seed_write(32'h{a:x},{n},{index*16});\n"
seed+='@(negedge core_clk);preload_done=1;$display("VENDOR CPU RELEASE t=%0t",$time);\nend\n'
tb=(ROOT/'sim/ai/TB_spi_model_commit.v').read_text()
tb=tb.replace('    soc #(',seed+'\n    soc #(',1)
tb=tb.replace('.clk(clk),.rst_n(rst_n),.spi_clk(sck)', '.clk(clk),.rst_n(rst_n&&preload_done),.spi_clk(sck)',1)
port_names={'awuser_ap':'awap','aruser_ap':'arap','awuser_id':'awid','aruser_id':'arid'}
for n in native:
    port='cpu_'+port_names.get(n,n)
    tb=tb.replace(f'.{port}(axi_{n})',f'.{port}(preload_done ? axi_{n} : p_{n})')
physical='''wire mem_rst_n,mem_ck,mem_ck_n,mem_cke,mem_ras_n,mem_cas_n,mem_we_n,mem_odt;
wire [14:0] mem_a;wire [2:0] mem_ba;wire [15:0] mem_dq;wire [1:0] mem_dqs,mem_dqs_n,mem_dm;
reg grs_n=0;initial #5 grs_n=1;GTP_GRS GRS_INST(.GRS_N(grs_n));
wire #0.15 dev_rst_n=mem_rst_n,dev_ck=mem_ck,dev_ck_n=mem_ck_n,dev_cke=mem_cke,dev_ras_n=mem_ras_n,dev_cas_n=mem_cas_n,dev_we_n=mem_we_n,dev_odt=mem_odt;
wire [14:0] #0.15 dev_a=mem_a;wire [2:0] #0.15 dev_ba=mem_ba;
ddr3_device_model device(.rst_n(dev_rst_n),.ck(dev_ck),.ck_n(dev_ck_n),.cke(dev_cke),.cs_n(1'b0),.ras_n(dev_ras_n),.cas_n(dev_cas_n),.we_n(dev_we_n),.addr(dev_a),.ba(dev_ba),.odt(dev_odt),.dq(mem_dq),.dqs(mem_dqs),.dqs_n(mem_dqs_n),.dm_tdqs(mem_dm),.tdqs_n());
'''
tb=tb.replace('    wire core_clk',physical+'\n    wire core_clk',1)
pins=['mem_rst_n','mem_ck','mem_ck_n','mem_cke','mem_ras_n','mem_cas_n','mem_we_n','mem_odt','mem_a','mem_ba','mem_dq','mem_dqs','mem_dqs_n','mem_dm']
tb=tb.replace('.sys_clk(clk),.sys_rst_n(rst_n)',','.join(f'.{p}({p})' for p in pins)+',\n        .sys_clk(clk),.sys_rst_n(rst_n)',1)
tb=tb.replace('if(shared_fault)$fatal', 'if(preload_done&&shared_fault)$fatal')
tb=tb.replace('#3000000;', '#5000000;')
tb+='\n' # preserve all production RTL files
(OUT/'TB_spi_vendor.v').write_text(tb)
fixture=(ROOT/'build/spi-model-commit/model_commit_fixture.vh').read_text().split('integer i;',1)[1]
fixture='integer i;'+fixture
fixture=fixture.replace('wait(ready);','wait(preload_done);@(negedge core_clk);aw_count=0;ar_count=0;')
fixture=fixture.replace('PASS real firmware SPI CHUNK/COMMIT:', 'PASS vendor CPU SPI CHUNK/COMMIT:')
(OUT/'model_commit_fixture.vh').write_text(fixture)
commands=['onerror {quit -code 1 -f}','vmap work work']
# ModelSim 10.4 rejects these two forward net references. Move only the
# declarations in generated simulation copies; preserve all expressions/logic.
compat=OUT/'compat';compat.mkdir(exist_ok=True)
for file,signal in [('frame_ring_ddr3.v','wr_frame_id'),('ddr3_read_ctrl.v','rd_frame_id_comb')]:
    text=(ROOT/'rtl/video'/file).read_text(encoding='utf-8')
    declaration=re.search(r'^\s*wire\s+\[2:0\]\s+'+signal+r';',text,re.M).group().strip()
    text=text.replace(declaration,'',1)
    position=text.index('    assign '+('available=' if signal=='wr_frame_id' else 'protect_mask='))
    text=text[:position]+declaration+'\n'+text[position:]
    (compat/file).write_text(text,encoding='utf-8')
commands.append('vlog -work work {'+(compat/'frame_ring_ddr3.v').as_posix()+'} {'+(compat/'ddr3_read_ctrl.v').as_posix()+'}')
sources=[OUT/'TB_spi_vendor.v']
model_sources=[p for p in sorted((ROOT/'sim/models').glob('*.v')) if p.name!='GTP_CLKBUFG.v']
model_names={p.name for p in model_sources}
cpu_sources=[p for p in sorted((ROOT/'rtl').glob('*.v')) if p.name not in model_names]
explicit_sources=cpu_sources+model_sources+[OUT/'TB_spi_vendor.v']
commands += ['vlog -sv -mfcu -work work +define+PROG_FILE=\\"firmware/acore_dual_rom.hex\\"+DATA_FILE=\\"firmware/acore_dual_ram_bytes.hex\\" +incdir+{'+OUT.as_posix()+'} '+
             '-y {'+compat.as_posix()+'} '+' '.join('-y {'+(ROOT/d).as_posix()+'}' for d in ['rtl/rk_fspi','rtl/video'])+' +libext+.v '+ ' '.join('{'+p.as_posix()+'}' for p in explicit_sources),
             'vsim -voptargs=+acc -suppress 3486,3680,3781 -c work.TB_spi_model_commit',
             '''for {set step 0} {$step < 51} {incr step} {
 run 100 us
 puts "VENDOR CPU checkpoint boundary"
 if {[catch {checkpoint latest.pending} reason]} {puts "CHECKPOINT failed: $reason"} else {file rename -force latest.pending latest.ckp}
}''','quit -f']
commands=[command.replace('firmware/acore_dual_rom.hex',(ROOT/'firmware/acore_dual_rom.hex').as_posix()).replace('firmware/acore_dual_ram_bytes.hex',(ROOT/'firmware/acore_dual_ram_bytes.hex').as_posix()) for command in commands]
(OUT/'run.do').write_text('\n'.join(commands)+'\n')
env=os.environ.copy()
with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
    for n in ['LM_LICENSE_FILE','MGLS_LICENSE_FILE']:
        try:env[n]=winreg.QueryValueEx(key,n)[0]
        except FileNotFoundError:pass
report_path=ROOT/'reports/spi_image/vendor_cpu_spi_commit.json'
report=dict(state='running',passed=False,physical_vendor_model=True,real_cpu_firmware=True,
            actual_spi_pins=True,prefix_fast_forwarded_bytes=13372576,spi_uploaded_bytes=144,
            full_upload_verified=False,header_seeded_through_native=True,routed_delays_simulated=False,
            started=datetime.datetime.now().isoformat(),log='build/spi-vendor-commit/run.log')
report_path.write_text(json.dumps(report,indent=2)+'\n')
with (OUT/'run.log').open('w') as log:
    p=subprocess.Popen([str(MS/'vsim.exe'),'-c','-do','run.do'],cwd=OUT,env=env,stdout=log,stderr=subprocess.STDOUT)
    try:rc=p.wait(timeout=10800)
    except subprocess.TimeoutExpired:
        subprocess.run(['taskkill','/PID',str(p.pid),'/T','/F'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        rc=p.wait();report['state']='timeout'
text=(OUT/'run.log').read_text(errors='replace')
passed=rc==0 and 'PASS vendor CPU SPI CHUNK/COMMIT:' in text
report.update(passed=passed,exit_code=rc,finished=datetime.datetime.now().isoformat())
if report['state']!='timeout':report['state']='passed' if passed else 'failed'
report_path.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
if not passed:print(text[-5000:]);raise SystemExit(1)
