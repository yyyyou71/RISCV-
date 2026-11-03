"""Production CPU/firmware and real SPI pins: continuous model upload.

Runs under WSL/Verilator. No upload-prefix shortcuts, firmware pokes, or model
header preloads. DDR is behavioral; vendor PHY and routed delays are excluded.
--chunks is only a throughput/partial-run check and never certifies a full load.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,subprocess,time

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--chunks',type=int,default=0)
parser.add_argument('--timeout',type=int,default=14400)
parser.add_argument('--skip-build',action='store_true')
parser.add_argument('--random-stalls',action='store_true')
args=parser.parse_args()
OUT=ROOT/'build/spi-model-full';OUT.mkdir(parents=True,exist_ok=True)
manifest=json.loads((ROOT/'firmware/manifest.json').read_text())
for name,value in manifest['sources'].items():
    assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==value,name
for kind in ['rom','ram']:
    assert hashlib.sha256((ROOT/f'firmware/acore_dual_{kind}.hex').read_bytes()).hexdigest()==manifest[kind+'_sha256']
model=(ROOT/'build/board-ai/board_model.bin').read_bytes()
fnv=2166136261
for byte in model:fnv=((fnv^byte)*16777619)&0xffffffff
fixture=f'''
localparam integer MODEL_BYTES={len(model)};
reg [7:0] model_data[0:MODEL_BYTES-1];
integer fd,got,offset,size,j,k,limit_chunks,chunks=0;
reg [127:0] retained;
initial begin
 fd=$fopen("build/board-ai/board_model.bin","rb");
 if(!fd)$fatal(1,"model file open failed");
 got=$fread(model_data,fd);$fclose(fd);
 if(got!=MODEL_BYTES)$fatal(1,"model file length");
 if(!$value$plusargs("limit_chunks=%d",limit_chunks))limit_chunks=0;
 for(j=0;j<256;j=j+1)request[j]=0;
 repeat(6)@(negedge clk);rst_n=1;repeat(12)@(negedge clk);rst_n=0;
 repeat(12)@(negedge clk);rst_n=1;wait(ready);
 put32(16,123);put32(20,MODEL_BYTES);put32(24,32'h{fnv:08x});put32(28,32'h{fnv:08x});
 exchange(9,1,16);if(get32(16)!==0)$fatal(1,"BEGIN rejected");
 for(offset=0;offset<MODEL_BYTES;offset=offset+size)begin
  size=MODEL_BYTES-offset;if(size>224)size=224;
  put32(16,123);put32(20,offset);
  for(j=0;j<size;j=j+1)request[24+j]=model_data[offset+j];
  exchange(10,chunks+2,8+size);
  if(get32(16)!==0||get32(44)!==offset+size)$fatal(1,"CHUNK rejected offset=%h status=%h received=%0d",offset,get32(16),get32(44));
  chunks=chunks+1;
  if(chunks%256==0 || chunks==1)begin
   $display("FULL_UPLOAD_PROGRESS chunks=%0d received=%0d/%0d t=%0t",chunks,offset+size,MODEL_BYTES,$time);$fflush();
  end
  if(limit_chunks!=0 && chunks>=limit_chunks && offset+size<MODEL_BYTES)begin
   $display("PARTIAL_UPLOAD_PASS chunks=%0d bytes=%0d full_model_verified=0 t=%0t",chunks,offset+size,$time);$finish;
  end
 end
 put32(16,123);exchange(11,chunks+2,4);
 if(get32(16)!==0||get32(28)!==2)$fatal(1,"COMMIT rejected status=%h state=%h",get32(16),get32(28));
 // Verify every byte is still present after ALL later chunks and COMMIT.
 for(j=0;j<MODEL_BYTES;j=j+16)begin
  retained=ring.u_ddr3.load_word((32'h04000000+j)>>1);
  for(k=0;k<16;k=k+1)if(retained[k*8+:8]!==model_data[j+k])
   $fatal(1,"final DDR retention byte=%h got=%h expected=%h",j+k,retained[k*8+:8],model_data[j+k]);
 end
 if(native_written_bytes!=MODEL_BYTES)$fatal(1,"missing native writes %0d",native_written_bytes);
 $display("FULL_UPLOAD_PASS chunks=%0d bytes=%0d all_ddr_bytes_verified=1 t=%0t",chunks,MODEL_BYTES,$time);$finish;
end
integer native_written_bytes=0,beat_lane,logical_byte;
reg [27:0] native_write_address;
always @(posedge core_clk)if(rst_n)begin
 if(ring.m_awvalid&&ring.m_awready)native_write_address=ring.m_awaddr;
 if(ring.m_wready)begin
  logical_byte=(native_write_address<<1)-32'h04000000;
  if(ring.m_wstrb!==16'hffff)$fatal(1,"unexpected byte mask %h",ring.m_wstrb);
  if(logical_byte!=native_written_bytes)$fatal(1,"native write address skipped/aliased %h expected byte=%h",logical_byte,native_written_bytes);
  for(beat_lane=0;beat_lane<16;beat_lane=beat_lane+1)
   if(ring.m_wdata[beat_lane*8+:8]!==model_data[logical_byte+beat_lane])
    $fatal(1,"SPI/CPU/native write mismatch byte=%h",logical_byte+beat_lane);
  native_written_bytes=native_written_bytes+16;
  native_write_address=native_write_address+8;
 end
end
'''
(OUT/'model_commit_fixture.vh').write_text(fixture)
tb=(ROOT/'sim/ai/TB_spi_model_commit.v').read_text()
tb=tb.replace('if(ar_count>=8)$fatal(1,"unexpected read count");','')
tb=tb.replace('reads[ar_count]=ring.m_araddr;','if(ar_count<8)reads[ar_count]=ring.m_araddr;')
tb=tb.replace('$display("NATIVE WRITE addr=%h len=%0d",ring.m_awaddr,ring.m_awlen+1);','')
tb=tb.replace('$display("NATIVE READ addr=%h len=%0d",ring.m_araddr,ring.m_arlen+1);','')
tb=tb.replace('if(cpu.dev_we&&cpu.dev_addr_wr==32\'h31000)','if(1\'b0&&cpu.dev_we&&cpu.dev_addr_wr==32\'h31000)')
tb=tb.replace('$display("SPI op=%0d status=%0d network_state=%0d received=%0d",op,get32(16),get32(28),get32(44));','')
tb=tb.replace('#3000000;','#120000000000;')
(OUT/'TB_full.v').write_text(tb)
if not args.skip_build:
    command=['verilator','--binary','--timing','--build','-j','4','-O3','-Wno-fatal',
             '--top-module','TB_spi_model_commit','--Mdir',str(OUT/'obj'),'-I'+str(OUT),
             '-y','sim/models','-y','rtl','-y','rtl/rk_fspi','-y','rtl/video',
             '-DDDR3_MODEL_SLOTS=1048576','-DDDR3_MODEL_STRICT_READS',
             '-DPROG_FILE="firmware/acore_dual_rom.hex"','-DDATA_FILE="firmware/acore_dual_ram_bytes.hex"',
             str(OUT/'TB_full.v'),'sim/ddr3/ddr3.sv']
    with (OUT/'compile.log').open('w') as f:
        subprocess.run(command,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=900)
suffix=('partial-'+str(args.chunks)) if args.chunks else ('full-random' if args.random_stalls else 'full')
report_path=ROOT/'reports/spi_image'/f'continuous_upload_{suffix}.json'
report=dict(state='running',passed=False,full_model_verified=False,model_bytes=len(model),
            firmware_elf_sha256=manifest['elf_sha256'],model_sha256=hashlib.sha256(model).hexdigest(),
            prefix_fast_forwarded_bytes=0,header_preloaded=False,physical_vendor_model=False,
            routed_delays_simulated=False,started=datetime.datetime.now().isoformat(),
            log=f'build/spi-model-full/{suffix}.log')
report_path.write_text(json.dumps(report,indent=2)+'\n')
command=[str(OUT/'obj/VTB_spi_model_commit'),f'+limit_chunks={args.chunks}']
if args.random_stalls:command+=['+ddr3_random_stalls=1','+ddr3_seed=12345']
started=time.monotonic()
with (OUT/f'{suffix}.log').open('w') as f:
    try:
        result=subprocess.run(command,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,timeout=args.timeout)
        report['exit_code']=result.returncode
    except subprocess.TimeoutExpired:report['exit_code']=None;report['state']='timeout'
log=(OUT/f'{suffix}.log').read_text(errors='replace')
passed=report['exit_code']==0 and ('PARTIAL_UPLOAD_PASS' if args.chunks else 'FULL_UPLOAD_PASS') in log
report.update(passed=passed,full_model_verified=passed and not args.chunks,
              wall_seconds=time.monotonic()-started,finished=datetime.datetime.now().isoformat())
if report['state']!='timeout':report['state']='passed' if passed else 'failed'
report_path.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2),flush=True)
if not passed:raise SystemExit(1)
