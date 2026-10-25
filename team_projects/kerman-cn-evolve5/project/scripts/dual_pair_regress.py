"""Architectural differential checks plus observed dual-lane hazard coverage."""
import csv,json,os,shutil,sys
from pathlib import Path
from regress import PROJECT,run_command
from front_configs import CONFIGS,parameters
from dual_testbench import dualize_core_tb
sys.path.insert(0,str(PROJECT/'tests'))
from generate import i,r,s,u,image,ECALL,NOP,write_image
from reference import pack
from m_reference import MModel

build=PROJECT.parents[1]/'work/dual1_pair_checks';build.mkdir(exist_ok=True);(build/'cases').mkdir(exist_ok=True)
report=PROJECT/'reports/dual_pairs';report.mkdir(parents=True,exist_ok=True)
state={'status':'running','hardware_tested':False};cases=[];programs=[]
def add(name,words,cause=11,reset=0,data=None):
    binary=image(words,data);m=MModel(binary);trace=m.run();trace[-1]['next_pc']=0xe000
    assert trace[-1]['cause']==cause
    write_image(build/'cases'/f'{name}.hex',binary)
    (build/'cases'/f'{name}.gold').write_text(''.join(pack(row)+'\n' for row in trace))
    for im,dm in ((0,0),(1,1),(2,2),(0,3)):
        cases.append(f'{name}_i{im}d{dm} cases/{name}.hex cases/{name}.gold {len(trace)} {im} {dm} 20261022 {reset}')
    programs.append(dict(name=name,packets=len(trace),cause=cause))

add('same_pair_raw',[i(0,1,0,7),i(0,2,1,9),ECALL])
add('same_pair_waw',[i(0,1,0,7),i(0,1,0,9),ECALL])
add('same_pair_war',[i(0,1,2,5),i(0,2,0,7),r(0,3,1,2),ECALL])
add('same_pair_x0',[i(0,0,0,7),i(0,0,0,9),i(0,1,0,3),i(0,2,0,5),ECALL])
add('forward_both_m_lanes',[i(0,1,0,5),i(0,2,0,7),r(0,3,1,2),r(0,4,2,1),r(0,1,3,4),r(0,2,4,3),r(0,5,1,2),r(0,6,2,1),ECALL])
add('forward_both_w_lanes',[i(0,1,0,5),i(0,2,0,7),i(0,8,0,11),i(0,9,0,13),r(0,3,1,2),r(0,4,2,1),ECALL])
add('held_load_and_buddy',[u(28,8),NOP,i(0,1,0,5),i(0,2,0,7),i(2,3,28,0,3),r(0,4,1,2),r(0,5,4,1),r(0,6,3,2),ECALL],data={0x8000:(0x12345678).to_bytes(4,'little')})
add('held_store_and_buddy',[u(28,8),NOP,i(0,1,0,5),i(0,2,0,7),s(2,28,1,0),r(0,4,1,2),r(0,5,4,1),r(0,6,2,1),ECALL])
for op in range(8):
    add(f'm_{op}_and_buddy',[i(0,1,0,-101),i(0,2,0,7),NOP,NOP,r(op,3,1,2,1),i(0,4,0,31),r(0,5,3,4),r(0,6,4,3),ECALL])
for store in (False,True):
    for op in (0,5):
        words=[i(0,1,0,101),i(0,2,0,7),u(28,15),0x0ff0000f,NOP,NOP,NOP,
               s(2,28,1,0) if store else i(2,3,28,0,3),r(op,4,1,2,1),i(0,5,0,31),ECALL]
        add(f'older_{"store" if store else "load"}_fault_kills_m{op}_buddy',words,7 if store else 5)
for op in (0,5):
    add(f'reset_m{op}_and_buddy',[i(0,1,0,101),i(0,2,0,7),NOP,NOP,r(op,3,1,2,1),i(0,4,0,31),ECALL],reset=2)

coverage=r'''
    integer craw=0,cwaw=0,cwar=0,cx0=0,cm0=0,cm1=0,cw0=0,cw1=0,cmdual=0,cload=0,cstore=0,ckill=0;
    always @(posedge clk) if(!rst && checking)begin
        if(dut.id_valid && dut.id2_valid && dut.id_ready)begin
            if(dut.pair_raw)begin craw=craw+1;if(dut.issue_pair)$fatal(1,"RAW paired");end
            if(dut.pair_waw)begin cwaw=cwaw+1;if(dut.issue_pair)$fatal(1,"WAW paired");end
            if(dut.issue_pair)begin
                if(dut.id2_rd!=0 && ((dut.id_use1 && dut.id_rs1==dut.id2_rd)||(dut.id_use2 && dut.id_rs2==dut.id2_rd)))cwar=cwar+1;
                if(dut.id_rd==0 && dut.id2_rd==0)cx0=cx0+1;
            end
        end
        if(dut.x_valid && dut.x2_valid)begin
            if(dut.x_mop && dut.md_request)cmdual=cmdual+1;
            if(dut.md_kill && (dut.md_issued || dut.md_valid))ckill=ckill+1;
            if(dut.x_fire)begin
                if(dut.x_load)cload=cload+1;
                if(dut.x_store)cstore=cstore+1;
                if(dut.m_valid && dut.m_we && (!dut.m_load || dut.load_available) && !dut.m_trap && dut.m_rd!=0 &&
                   ((dut.x2_use1 && dut.x2_rs1==dut.m_rd)||(dut.x2_use2 && dut.x2_rs2==dut.m_rd)))cm0=cm0+1;
                if(dut.m2_valid && dut.m2_we && dut.m2_rd!=0 &&
                   ((dut.x_use1 && dut.x_rs1==dut.m2_rd)||(dut.x_use2 && dut.x_rs2==dut.m2_rd)||
                    (dut.x2_use1 && dut.x2_rs1==dut.m2_rd)||(dut.x2_use2 && dut.x2_rs2==dut.m2_rd)))cm1=cm1+1;
                if(dut.retire_rd_we && ((dut.x2_use1 && dut.x2_rs1==dut.w_rd)||(dut.x2_use2 && dut.x2_rs2==dut.w_rd)))cw0=cw0+1;
                if(dut.retire2_rd_we && ((dut.x_use1 && dut.x_rs1==dut.w2_rd)||(dut.x_use2 && dut.x_rs2==dut.w2_rd)||
                    (dut.x2_use1 && dut.x2_rs1==dut.w2_rd)||(dut.x2_use2 && dut.x2_rs2==dut.w2_rd)))cw1=cw1+1;
            end
        end
    end
'''
finish=r'''
        $display("PAIR_COVERAGE raw=%0d waw=%0d war=%0d x0=%0d m0=%0d m1=%0d w0=%0d w1=%0d m_pair=%0d load=%0d store=%0d kill=%0d",craw,cwaw,cwar,cx0,cm0,cm1,cw0,cw1,cmdual,cload,cstore,ckill);
        if(craw==0 || cwaw==0 || cwar==0 || cx0==0 || cm0==0 || cm1==0 || cw0==0 || cw1==0 || cmdual==0 || cload==0 || cstore==0 || ckill==0)$fatal(1,"Missing dual hazard coverage");
'''
try:
    (build/'manifest.txt').write_text('\n'.join(cases)+'\n')
    (build/'args.txt').write_text('--testplusarg MANIFEST=manifest.txt\n--testplusarg RESULTS=results.csv\n--testplusarg TRACE=retire.log\n')
    tb=(PROJECT/'sim/tb_core.sv').read_text().replace(".RESET_MTVEC(32'he000)",".M_ENABLE(1),.RESET_MTVEC(32'he000),"+parameters(CONFIGS['dual']))
    tb=dualize_core_tb(tb,1).replace('    task automatic initialize_case;',coverage+'\n    task automatic initialize_case;')
    tb=tb.replace('        $display("REGRESSION_PASS',finish+'\n        $display("REGRESSION_PASS')
    tb=tb.replace('if (warm_reset != 0) begin','''if(warm_reset==2)begin
                    while(!(dut.md_issued && dut.x2_valid) && wait_cycles<1000)begin @(posedge clk);#1;wait_cycles=wait_cycles+1;end
                    if(!(dut.md_issued && dut.x2_valid))$fatal(1,"Reset did not reach M pair");
                    initialize_case();
                end
                if (warm_reset == 1) begin''')
    (build/'tb.sv').write_text(tb)
    env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sorted((PROJECT/'rtl').glob('*.v')),build/'tb.sv'],build,build/'compile.log',env)
    run_command([vb/'xelab.bat','tb_core','-s','pairs'],build,build/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','pairs','-runall','-f','args.txt'],build,build/'simulate.log',env)
    assert f'REGRESSION_PASS cases={len(cases)}' in out and 'Fatal:' not in out,out[-5000:]
    rows=list(csv.DictReader((build/'results.csv').open()))
    state.update(status='passed',cases=len(cases),programs=programs,packets=sum(int(x['packets']) for x in rows),pairs=sum(int(x['pairs']) for x in rows),coverage=[x for x in out.splitlines() if x.startswith('PAIR_COVERAGE')])
    print('DUAL_PAIR_PASS',len(cases),flush=True)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:
    for name in ('tb.sv','manifest.txt','results.csv','compile.log','elaborate.log','simulate.log'):
        if (build/name).exists():shutil.copy2(build/name,report/name)
    shutil.copytree(build/'cases',report/'cases',dirs_exist_ok=True)
    (report/'result.json').write_text(json.dumps(state,indent=2))
