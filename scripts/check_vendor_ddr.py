"""Run installed ModelSim against the project's actual Pango DDR IP.

Uses existing licensed tools and vendor libraries without copying protected IP
into Git. The Micron model shipped in the working reference supplies the device.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,subprocess,winreg

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--controller-only',action='store_true',help='Original vendor controller with ideal DFI memory and direct clock; excludes PHY.')
parser.add_argument('--timeout',type=int,default=600,help='Maximum wall-clock seconds.')
parser.add_argument('--checkpoint-us',type=int,default=20,help='Full PHY simulation checkpoint interval in simulated microseconds.')
args=parser.parse_args()
run_name='vendor-ddr-controller' if args.controller_only else 'vendor-ddr'
OUT=ROOT/'build'/run_name;OUT.mkdir(parents=True,exist_ok=True)
PDS=Path('C:/diskE/FPGA_Learning/PGenvironment/PDS_2022.2-SP6.1')
MS=Path('C:/diskE/modelsim/win64')
REF=Path('C:/Users/yyyyou71/Desktop/purple-light-fpga-main/purple-light-fpga-main/ipcore/ddr3')
SIMLIB=PDS/'ip/system_ip/ips2l_hmic_s/ips2l_hmic_eval/ips2l_hmic_s/sim_lib'
PRIM=PDS/'arch/vendor/pango/verilog/simulation'
env=os.environ.copy()
with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
    for name in ['LM_LICENSE_FILE','MGLS_LICENSE_FILE']:
        try:env[name]=winreg.QueryValueEx(key,name)[0]
        except FileNotFoundError:pass

source=(ROOT/'ipcore/ddr3/ddr3.v').read_text()
if args.controller_only:
    # Preserve all real controller parameters, its native interface, reset
    # synchronizer, and instance verbatim. Only the PHY instance is replaced.
    controller_source=source[:source.index('\n ddr3_ddrphy_top  #(')]
    controller_source+='''
reg test_clock=0;
always #3.80952381 test_clock=~test_clock; // 131.25 MHz
assign ddrphy_sysclk=test_clock;
assign dfi_init_complete=resetn;
assign dfi_phyupd_req=1'b0;
vendor_dfi_memory ideal_memory(
 .clk(ddrphy_sysclk),.rst_n(ddrc_rstn),
 .address(dfi_address),.bank(dfi_bank),.cs_n(dfi_cs_n),
 .ras_n(dfi_ras_n),.cas_n(dfi_cas_n),.we_n(dfi_we_n),
 .wrdata(dfi_wrdata),.wrdata_en(dfi_wrdata_en),.wrdata_mask(dfi_wrdata_mask),
 .rddata(dfi_rddata),.rddata_valid(dfi_rddata_valid));
endmodule
'''
    (OUT/'ddr3_controller_only.v').write_text(controller_source)
inputs=re.findall(r'^\s*input\s+(?:\[[^\]]+\]\s*)?(\w+)',source,re.M)
outputs=re.findall(r'^\s*(?:output|inout)\s+(?:\[[^\]]+\]\s*)?(\w+)',source,re.M)
links={name:name for name in inputs+outputs if name.startswith(('axi_','mem_'))}
links.update(ref_clk='clk',resetn='rst_n',core_clk='core_clk',ddr_init_done='ready')
for name in inputs:
    if name not in links:links[name]="1'b1" if name=='dbg_ddrphy_rst_n' else "'0"
(OUT/'vendor_ddr_instance.vh').write_text('ddr3 dut(\n'+',\n'.join(f' .{n}({v})' for n,v in links.items())+'\n);\n')
device=(REF/'example_design/bench/mem/ddr3.v').read_text()
device=device.replace('module ddr3 (','module ddr3_device_model (',1)
device=device.replace('../../example_design/bench/mem/ddr3_parameters.vh',(REF/'example_design/bench/mem/ddr3_parameters.vh').as_posix())
(OUT/'ddr3_device_model.v').write_text(device)

model=(ROOT/'build/board-ai/board_model_addrprobe.bin').read_bytes()
plans=[(0x10000,64),(0x5000,64),(0xc10000,224),(0xc05000,224),(0xcc0ca0,144)]
fixture='reg [127:0] expected[0:79];\ninteger job,i,lane;\ninitial begin\n'
for job,(address,size) in enumerate(plans):
    for offset in range(0,size,16):
        value=int.from_bytes(model[address+offset:address+offset+16],'little')
        fixture+=f" expected[{job*16+offset//16}]=128'h{value:032x};\n"
fixture+=' wait(ready);$display("VENDOR DDR initialization complete t=%0t",$time);\n'
for job,(address,size) in enumerate(plans):
    fixture+=f' for(i=0;i<{size//16};i=i+1)tx[i]=expected[{job*16}+i];\n'
    fixture+=f" execute(1,32'h{0x4000000+address:x},{size});\n"
for job in [4,0,1]:
    address,size=plans[job]
    fixture+=f" execute(0,32'h{0x4000000+address:x},{size});\n"
    fixture+=f' for(i=0;i<{size//16};i=i+1)if(rx[i]!==expected[{job*16}+i])$fatal(1,"vendor read mismatch job={job} word=%0d got=%h expected=%h",i,rx[i],expected[{job*16}+i]);\n'
fixture+=' tx[0]=128\'h00112233445566778899aabbccddeeff;execute(1,32\'h04e00000,16);\n'
fixture+=' for(lane=0;lane<16;lane=lane+1)begin\n'
fixture+='  write_mask=16\'b1<<lane;tx[0]=128\'haaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;execute(1,32\'h04e00000,16);\n'
fixture+='  execute(0,32\'h04e00000,16);\n'
fixture+='  for(i=0;i<16;i=i+1)if(rx[0][i*8+:8] !== (i<=lane?8\'haa:(8\'hff-i*17)))$fatal(1,"WSTRB byte mapping lane=%0d byte=%0d",lane,i);\n'
fixture+=' end\n $display("PASS vendor DDR: real controller/PHY/device, model/post retention after later writes, all 16 byte strobes");$finish;\nend\n'
if args.controller_only:
    fixture=fixture.replace('real controller/PHY/device','real controller, ideal DFI memory, no PHY')
(OUT/'vendor_ddr_fixture.vh').write_text(fixture)
sources=[]
for line in (REF/'sim/modelsim/sim_file_list.f').read_text().splitlines():
    line=line.strip()
    if '/sim_lib/' in line:sources.append(SIMLIB/line.split('/sim_lib/',1)[1])
    elif '/arch/vendor/' in line:sources.append(PDS/'arch/vendor'/line.split('/arch/vendor/',1)[1])
for i,p in enumerate(sources):
    if not p.is_file() and p.with_suffix('.vp').is_file():sources[i]=p.with_suffix('.vp')
    if not sources[i].is_file():
        generated=ROOT/'ipcore/ddr3/rtl'/p.relative_to(SIMLIB)
        if generated.is_file():sources[i]=generated
    assert sources[i].is_file(),sources[i]
if args.controller_only:
    sources += [OUT/'ddr3_controller_only.v',ROOT/'sim/ddr3/vendor_dfi_memory.sv']
else:
    # Explicit SV compilation avoids ModelSim 10.4's library-auto-compilation
    # problem observed around the public PPLL model's real-valued calculations.
    sources += [ROOT/'ipcore/ddr3/ddr3.v',ROOT/'ipcore/ddr3/ddr3_ddrphy_top.v',OUT/'ddr3_device_model.v']
sources += [ROOT/'rtl/ddr_block_transfer.v',ROOT/'sim/ddr3/TB_vendor_ddr_retention.v']
defines='+define+IPS_DDR_SPEEDUP_SIM+RTL_SIM+den4096Mb+x16+sg187E'
if args.controller_only:defines+='+VENDOR_CONTROLLER_ONLY'
commands=['onerror {quit -code 1 -f}','vlib work','vmap work work',
 'vlog -sv -work work {'+str(PRIM.as_posix())+'/modelsim10.2c/adc_e2_source_codes/*.vp}',
 'vlog -sv -mfcu -suppress 2902 -work work '+defines+' +incdir+{'+OUT.as_posix()+'} -y {'+PRIM.as_posix()+'} +libext+.v '+ ' '.join('{'+p.as_posix()+'}' for p in sources)]
if not args.controller_only:
    commands.append('vlog -sv -work work {'+(PRIM/'GTP_PPLL.v').as_posix()+'}')
    sources.append(PRIM/'GTP_PPLL.v')
access='' if args.controller_only else ' -voptargs=+acc'
commands+=['vsim'+access+' -suppress 3486,3680,3781 -c work.TB_vendor_ddr_retention']
if not args.controller_only and args.checkpoint_us>0:
    commands += [f'''for {{set step 0}} {{$step < {2000//args.checkpoint_us+1}}} {{incr step}} {{
 run {args.checkpoint_us} us
 if {{[catch {{checkpoint latest.pending}} reason]}} {{
  puts "VENDOR CHECKPOINT unavailable: $reason"
 }} else {{
  file rename -force latest.pending latest.ckp
  puts "VENDOR CHECKPOINT saved latest.ckp"
 }}
}}''']
else:commands.append('run -all')
commands.append('quit -f')
(OUT/'run.do').write_text('\n'.join(commands)+'\n')
report_path=ROOT/'reports/spi_image'/f'{run_name.replace("-","_")}.json'
if report_path.is_file():(OUT/'previous_run_report.json').write_text(report_path.read_text())
if (OUT/'run.log').is_file():(OUT/'previous_run.log').write_bytes((OUT/'run.log').read_bytes())
report=dict(passed=False,state='running',started=datetime.datetime.now().isoformat(),
            log=f'build/{run_name}/run.log',physical_vendor_model=not args.controller_only,
            original_vendor_controller=True,ideal_clock=args.controller_only,
            ideal_dfi_memory=args.controller_only,post_route_delays=False,rtl_modified=False,
            write_strobe_document='UG042003 table 2-10',wall_timeout_seconds=args.timeout,
            checkpoint_interval_us=args.checkpoint_us if not args.controller_only else None,
            vendor_model_sources={p.as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
report_path.write_text(json.dumps(report,indent=2)+'\n')
timed_out=False
with (OUT/'run.log').open('w') as log:
    process=subprocess.Popen([str(MS/'vsim.exe'),'-c','-do','run.do'],cwd=OUT,env=env,stdout=log,stderr=subprocess.STDOUT)
    try:exit_code=process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out=True
        subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        exit_code=process.wait()
text=(OUT/'run.log').read_text(errors='replace')
passed=not timed_out and exit_code==0 and 'PASS vendor DDR:' in text
print(text[-5000:])
report.update(passed=passed,state='timeout' if timed_out else ('passed' if passed else 'failed'),
              exit_code=exit_code,finished=datetime.datetime.now().isoformat())
report_path.write_text(json.dumps(report,indent=2)+'\n')
if not passed:raise SystemExit(1)
