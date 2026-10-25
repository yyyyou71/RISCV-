import json,os,sys,shutil,csv,argparse
from pathlib import Path
from regress import PROJECT as P,run_command
from front_configs import CONFIGS,parameters
from dual_testbench import dualize_core_tb
sys.path.insert(0,str(P/'tests'))
from generate import i,r,b,j,u,s,image,write_image,ECALL,NOP
from m_reference import MModel
from reference import pack
ap=argparse.ArgumentParser();ap.add_argument('--config',choices=CONFIGS,default='fast_both');args=ap.parse_args()
W=P.parents[1]/'work/evolve5_lsu_directed';W.mkdir(exist_ok=True);(W/'cases').mkdir(exist_ok=True)
R=P/'reports/lsu_directed';R.mkdir(parents=True,exist_ok=True)
cases=[];programs=[];state=dict(status='running',hardware_tested=False)
def add(name,words,cause=11):
    binary=image(words);model=MModel(binary);trace=model.run();trace[-1]['next_pc']=0xe000;assert trace[-1]['cause']==cause
    write_image(W/'cases'/f'{name}.hex',binary)
    (W/'cases'/f'{name}.gold').write_text(''.join(pack(row)+'\n' for row in trace))
    for im,dm in ((0,0),(1,1),(2,2),(0,3)):cases.append(f'{name}_i{im}d{dm} cases/{name}.hex cases/{name}.gold {len(trace)} {im} {dm} 20261023 0')
    programs.append(dict(name=name,packets=len(trace),cause=cause))

for f3,off in ((0,0),(0,1),(0,2),(0,3),(1,0),(1,2),(2,0),(4,1),(5,2)):
    setup=[u(28,8),i(0,1,0,-128),0x0ff0000f,NOP]
    # An independent ALU is older than every second-slot access.
    add(f'load_f{f3}_o{off}',setup+[s(2,28,1,0),NOP,0x0ff0000f,NOP,i(0,2,0,17),i(f3,3,28,off,3),r(0,4,3,2),ECALL])
for f3,off in ((0,0),(0,1),(0,2),(0,3),(1,0),(1,2),(2,0)):
    add(f'store_f{f3}_o{off}',[u(28,8),i(0,1,0,-128),0x0ff0000f,NOP,i(0,2,0,17),s(f3,28,1,off),i(2,3,28,0,3),ECALL])
for store in (False,True):
    for f3,off in ((1,1),(2,1),(2,2)):
        op=s(f3,28,1,off) if store else i(f3,3,28,off,3)
        add(f'misaligned_{store}_{f3}_{off}',[u(28,8),i(0,1,0,9),0x0ff0000f,NOP,i(0,2,0,17),op,i(0,4,0,99),ECALL],6 if store else 4)
    op=s(2,28,1,0) if store else i(2,3,28,0,3)
    add(f'access_fault_{store}',[u(28,15),i(0,1,0,9),0x0ff0000f,NOP,i(0,2,0,17),op,i(0,4,0,99),s(2,28,1,4),ECALL],7 if store else 5)
    add(f'fault_cancels_m_{store}',[u(28,15),i(0,1,0,9),0x0ff0000f,NOP,i(0,2,0,17),op,r(0,7,1,2,1),i(0,8,0,99),ECALL],7 if store else 5)
add('second_load_x0',[u(28,8),NOP,0x0ff0000f,NOP,i(0,2,0,17),i(2,0,28,0,3),r(0,3,0,2),ECALL])
add('second_load_raw_reject',[u(28,8),NOP,0x0ff0000f,NOP,i(0,28,28,4),i(2,3,28,0,3),ECALL])
add('second_load_waw_reject',[u(28,8),NOP,0x0ff0000f,NOP,i(0,3,0,17),i(2,3,28,0,3),ECALL])
add('second_load_war_allowed',[u(28,8),i(0,3,0,7),0x0ff0000f,NOP,i(0,2,3,1),i(2,3,28,0,3),ECALL])
for target in (32,33,34):
    add(f'jalr_target_{target}',[i(0,1,0,target),NOP,0x0ff0000f,NOP,i(0,2,0,17),i(0,7,1,0,0x67),i(0,4,0,99),NOP,r(0,8,7,2),ECALL],0 if target==34 else 11)
add('jalr_raw_reject',[i(0,1,0,16),i(0,7,1,0,0x67),i(0,2,0,99),NOP,ECALL])
add('jalr_return_second',[i(0,1,0,16),NOP,i(0,2,0,17),i(0,0,1,0,0x67),ECALL])
try:
    (W/'manifest.txt').write_text('\n'.join(cases)+'\n')
    (W/'args.txt').write_text('--testplusarg MANIFEST=manifest.txt\n--testplusarg RESULTS=results.csv\n--testplusarg TRACE=retire.log\n')
    tb=(P/'sim/tb_core.sv').read_text().replace(".RESET_MTVEC(32'he000)",".M_ENABLE(1),.RESET_MTVEC(32'he000),"+parameters(CONFIGS[args.config]))
    tb=dualize_core_tb(tb,1)
    tb=tb.replace('    task automatic initialize_case;', '''    integer paired_controls=0,paired_jals=0,loads2=0,stores2=0,exceptions2=0;
    always @(posedge clk)if(!rst && checking && dut.secondary_exception_pending)begin
        exceptions2=exceptions2+1;
        if(dv || dut.id_ready || dut.md_request)$fatal(1,"Younger work escaped secondary exception");
    end
    always @(posedge clk)if(!rst && checking && tv2)begin
        if(tinsn2[6:0]==7'h03)loads2=loads2+1;
        if(tinsn2[6:0]==7'h23)stores2=stores2+1;
        if(tinsn2[6:0]==7'h63)paired_controls=paired_controls+1;
        if(tinsn2[6:0]==7'h67)paired_jals=paired_jals+1;
    end
    task automatic initialize_case;''')
    tb=tb.replace('        $display("REGRESSION_PASS', '''        if(loads2<10 || stores2<10 || exceptions2<10 || paired_jals==0)$fatal(1,"Branch pairing not exercised");
        $display("LSU_COVERAGE loads=%0d stores=%0d exceptions=%0d jalr=%0d",loads2,stores2,exceptions2,paired_jals);
        $display("REGRESSION_PASS''')
    (W/'tb.sv').write_text(tb)
    env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    run_command([vb/'xvlog.bat','-sv','-i',P/'rtl',*sorted((P/'rtl').glob('*.v')),W/'tb.sv'],W,W/'compile.log',env)
    run_command([vb/'xelab.bat','tb_core','-s','branch_directed'],W,W/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','branch_directed','-runall','-f','args.txt'],W,W/'simulate.log',env)
    assert f'REGRESSION_PASS cases={len(cases)}' in out and 'Fatal:' not in out,out[-5000:]
    rows=list(csv.DictReader((W/'results.csv').open()))
    state.update(status='passed',cases=len(cases),programs=programs,packets=sum(int(x['packets']) for x in rows),coverage=[x for x in out.splitlines() if 'LSU_COVERAGE' in x])
    print('LSU_DIRECTED_PASS',len(cases),flush=True)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:
    for name in ('tb.sv','manifest.txt','results.csv','compile.log','elaborate.log','simulate.log'):
        if(W/name).exists():shutil.copy2(W/name,R/name)
    shutil.copytree(W/'cases',R/'cases',dirs_exist_ok=True)
    (R/'result.json').write_text(json.dumps(state,indent=2),encoding='utf-8')
