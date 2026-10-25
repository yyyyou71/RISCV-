import json,os,sys,shutil
from pathlib import Path
from regress import PROJECT,run_command
sys.path.insert(0,str(PROJECT/'tests'));from front_predict_reference import vectors
env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
report=PROJECT/'reports/front_predict_units';report.mkdir(parents=True,exist_ok=True)
results=[]
for bits,pht,depth,gs in ((2,6,4,1),(8,10,16,1),(6,8,8,0)):
    name=f'b{bits}_p{pht}_r{depth}_g{gs}'; build=PROJECT.parents[1]/'work'/('evolve5_pred_'+name);build.mkdir(exist_ok=True)
    rows=vectors(bits,pht,depth,gs)
    assert all(len(row)==22 for row in rows)
    (build/'vectors.hex').write_text(''.join(''.join(f'{x:08x}' for x in row)+'\n' for row in rows))
    tb=f'''`timescale 1ns/1ps
module tb_front_predict;
reg clk=0;always #5 clk=~clk;
reg rst=1,flush=0,err=0,uv=0,uc=0,ut=0;
reg [31:0] qp=0,qi=0,up=0,ui=0,target=0;
reg [{pht-1}:0] idx=0;
wire hit,taken,rh;wire [31:0] npc;wire [{pht-1}:0] qidx;
rv32_predictor #(.INDEX_BITS({bits}),.PHT_BITS({pht}),.GSHARE_ENABLE({gs}),.RAS_DEPTH({depth})) dut(
.clk(clk),.rst(rst),.query_pc(qp),.query_insn(qi),.query_error(err),.hit(hit),.taken(taken),.next_pc(npc),.prediction_index(qidx),.ras_hit(rh),
.update_valid(uv),.update_conditional(uc),.update_taken(ut),.update_pc(up),.update_target(target),.update_insn(ui),.update_index(idx),.context_flush(flush));
reg [703:0] rows[0:{len(rows)-1}];reg [31:0] a[0:21];integer n,k;
task check(input integer off);begin
if(hit!==a[off][0] || taken!==a[off+1][0] || npc!==a[off+2] || qidx!==a[off+3][{pht-1}:0] || rh!==a[off+4][0])
$fatal(1,"Prediction mismatch row=%0d phase=%0d pc=%08x got=%b/%b/%08x/%h/%b",n,off,qp,hit,taken,npc,qidx,rh);
end endtask
initial begin
$readmemh("vectors.hex",rows);repeat(3) @(posedge clk);
for(n=0;n<{len(rows)};n=n+1) begin
@(negedge clk);for(k=0;k<22;k=k+1) a[k]=rows[n][(21-k)*32+:32];
rst=a[0][0];flush=a[1][0];qp=a[2];qi=a[3];err=a[4][0];uv=a[5][0];up=a[6];ui=a[7];uc=a[8][0];ut=a[9][0];target=a[10];idx=a[11];
#1;check(12);@(posedge clk);#1;check(17);
end
$display("FRONT_PREDICT_PASS vectors={len(rows)}");$finish;
end
endmodule
'''
    (build/'tb.sv').write_text(tb)
    run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/rv32_predictor.v',build/'tb.sv'],build,build/'compile.log',env)
    run_command([vb/'xelab.bat','tb_front_predict','-s','pred'],build,build/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','pred','-runall'],build,build/'simulate.log',env)
    assert f'FRONT_PREDICT_PASS vectors={len(rows)}' in out,out[-2000:]
    dst=report/name;dst.mkdir(exist_ok=True)
    for f in ('tb.sv','vectors.hex','compile.log','elaborate.log','simulate.log'):shutil.copy2(build/f,dst/f)
    results.append(dict(name=name,vectors=len(rows),status='passed'))
(report/'result.json').write_text(json.dumps(dict(status='passed',configurations=results,oracle='Python sparse table/list model, pre-edge and post-edge outputs'),indent=2))
print('FRONT_PREDICT_ALL_PASS',flush=True)
