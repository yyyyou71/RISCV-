import json,os,sys,shutil,csv
from pathlib import Path
from regress import PROJECT as P,run_command
from front_configs import CONFIGS,parameters
from dual_testbench import dualize_core_tb
sys.path.insert(0,str(P/'tests'))
from generate import i,r,b,j,u,s as store_insn,image,write_image,ECALL,NOP
from m_reference import MModel
from reference import pack
W=P.parents[1]/'work/evolve5_mul_directed';W.mkdir(exist_ok=True);(W/'cases').mkdir(exist_ok=True)
R=P/'reports/mul_directed';R.mkdir(parents=True,exist_ok=True)
cases=[];programs=[];state=dict(status='running',hardware_tested=False)
def add(name,words,cause=11):
    binary=image(words);model=MModel(binary);trace=model.run();trace[-1]['next_pc']=0xe000;assert trace[-1]['cause']==cause
    write_image(W/'cases'/f'{name}.hex',binary)
    (W/'cases'/f'{name}.gold').write_text(''.join(pack(row)+'\n' for row in trace))
    for im,dm in ((0,0),(1,1),(2,2),(0,3)):cases.append(f'{name}_i{im}d{dm} cases/{name}.hex cases/{name}.gold {len(trace)} {im} {dm} 20261023 0')
    programs.append(dict(name=name,packets=len(trace),cause=cause))

def li(rd,value):return [u(rd,((value+0x800)>>12)&0xfffff),i(0,rd,rd,value&4095)]
for op in range(4):
    for a,c in ((0,0),(1,0xffffffff),(0x80000000,0xffffffff),(0x80000001,0x81234567),(0xffffffff,0xffffffff),(0x7fffffff,0x7fffffff)):
        setup=li(1,a)+li(2,c)+[0x0ff0000f,NOP,NOP,NOP]
        add(f'mul_slot{op}_{a:08x}_{c:08x}',setup+[i(0,10,0,17),r(op,3,1,2,1),r(0,4,3,10),ECALL])
for op in range(4):
    setup=li(1,0x81234567)+li(2,7)+[u(28,15),0x0ff0000f,NOP,NOP]
    add(f'older_load_fault_cancels_mul_slot{op}',setup+[i(2,5,28,0,3),r(op,3,1,2,1),ECALL],5)
    add(f'older_store_fault_cancels_mul_slot{op}',setup+[store_insn(2,28,1,0),r(op,3,1,2,1),ECALL],7)
add('two_mul_reject',li(1,101)+li(2,7)+[r(0,5,1,2,1),r(1,3,1,2,1),ECALL])
add('div_and_mul_reject',li(1,0x80000000)+li(2,0xffffffff)+[r(4,5,1,2,1),r(0,3,1,2,1),ECALL])
add('mul_raw_reject',li(2,7)+[i(0,1,0,101),r(0,3,1,2,1),ECALL])
add('mul_waw_reject',li(1,101)+li(2,7)+[i(0,3,0,17),r(0,3,1,2,1),ECALL])
add('mul_war_allowed',li(1,101)+li(2,7)+[i(0,3,0,17),NOP,0x0ff0000f,NOP,r(0,4,3,1),r(0,3,1,2,1),ECALL])
try:
    (W/'manifest.txt').write_text('\n'.join(cases)+'\n')
    (W/'args.txt').write_text('--testplusarg MANIFEST=manifest.txt\n--testplusarg RESULTS=results.csv\n--testplusarg TRACE=retire.log\n')
    tb=(P/'sim/tb_core.sv').read_text().replace(".RESET_MTVEC(32'he000)",".M_ENABLE(1),.RESET_MTVEC(32'he000),"+parameters(CONFIGS['mul_pair']))
    tb=dualize_core_tb(tb,1)
    tb=tb.replace('    task automatic initialize_case;', '''    integer pair_ops[0:3];integer z;initial for(z=0;z<4;z=z+1)pair_ops[z]=0;
    always @(posedge clk)if(!rst && checking && tv2)begin
        if(tinsn2[6:0]==7'h33 && tinsn2[31:25]==1)begin
            if(tinsn2[14])$fatal(1,"Unsupported second divider");
            pair_ops[tinsn2[13:12]]=pair_ops[tinsn2[13:12]]+1;
        end
    end
    task automatic initialize_case;''')
    tb=tb.replace('        $display("REGRESSION_PASS', '''        for(z=0;z<4;z=z+1)if(pair_ops[z]<4)$fatal(1,"MUL variant not paired");
        $display("MUL_SLOT_COVERAGE mul=%0d mulh=%0d mulhsu=%0d mulhu=%0d",pair_ops[0],pair_ops[1],pair_ops[2],pair_ops[3]);
        $display("REGRESSION_PASS''')
    (W/'tb.sv').write_text(tb)
    env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    run_command([vb/'xvlog.bat','-sv','-i',P/'rtl',*sorted((P/'rtl').glob('*.v')),W/'tb.sv'],W,W/'compile.log',env)
    run_command([vb/'xelab.bat','tb_core','-s','branch_directed'],W,W/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','branch_directed','-runall','-f','args.txt'],W,W/'simulate.log',env)
    assert f'REGRESSION_PASS cases={len(cases)}' in out and 'Fatal:' not in out,out[-5000:]
    rows=list(csv.DictReader((W/'results.csv').open()))
    state.update(status='passed',cases=len(cases),programs=programs,packets=sum(int(x['packets']) for x in rows),coverage=[x for x in out.splitlines() if 'MUL_SLOT_COVERAGE' in x])
    print('MUL_SLOT_DIRECTED_PASS',len(cases),flush=True)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:
    for name in ('tb.sv','manifest.txt','results.csv','compile.log','elaborate.log','simulate.log'):
        if(W/name).exists():shutil.copy2(W/name,R/name)
    shutil.copytree(W/'cases',R/'cases',dirs_exist_ok=True)
    (R/'result.json').write_text(json.dumps(state,indent=2),encoding='utf-8')
