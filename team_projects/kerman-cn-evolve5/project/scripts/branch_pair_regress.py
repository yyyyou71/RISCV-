import json,os,sys,shutil,csv
from pathlib import Path
from regress import PROJECT as P,run_command
from front_configs import CONFIGS,parameters
from dual_testbench import dualize_core_tb
sys.path.insert(0,str(P/'tests'))
from generate import i,r,b,j,u,s,image,write_image,ECALL,NOP
from m_reference import MModel
from reference import pack
W=P.parents[1]/'work/evolve5_branch_directed';W.mkdir(exist_ok=True);(W/'cases').mkdir(exist_ok=True)
R=P/'reports/branch_directed';R.mkdir(parents=True,exist_ok=True)
cases=[];programs=[];state=dict(status='running',hardware_tested=False)
def add(name,words,cause=11):
    binary=image(words);model=MModel(binary);trace=model.run();trace[-1]['next_pc']=0xe000;assert trace[-1]['cause']==cause
    write_image(W/'cases'/f'{name}.hex',binary)
    (W/'cases'/f'{name}.gold').write_text(''.join(pack(row)+'\n' for row in trace))
    for im,dm in ((0,0),(1,1),(2,2),(0,3)):cases.append(f'{name}_i{im}d{dm} cases/{name}.hex cases/{name}.gold {len(trace)} {im} {dm} 20261023 0')
    programs.append(dict(name=name,packets=len(trace),cause=cause))
for f3 in (0,1,4,5,6,7):
    for a,c in ((-1,1),(1,-1),(7,7)):
        words=[i(0,1,0,a),i(0,2,0,c),0x0ff0000f,NOP,i(0,3,0,11),b(f3,1,2,12),i(0,4,0,22),j(0,8),i(0,5,0,33),ECALL]
        add(f'branch_f{f3}_a{a}_b{c}',words)
add('jal_second_link',[i(0,3,0,11),j(7,12),i(0,4,0,99),i(0,5,0,88),r(0,8,7,3),ECALL])
add('jal_waw_reject',[i(0,7,0,11),j(7,12),i(0,4,0,99),NOP,r(0,8,7,0),ECALL])
add('branch_raw_reject',[i(0,1,0,11),b(1,1,0,8),i(0,2,0,99),ECALL])
add('misaligned_taken_fallback',[i(0,3,0,11),b(0,0,0,2),ECALL],0)
add('misaligned_not_taken_fallback',[i(0,1,0,1),NOP,i(0,3,0,11),b(0,1,0,2),ECALL])
add('faulting_load_suppresses_branch',[u(28,15),NOP,0x0ff0000f,NOP,i(2,3,28,0,3),b(0,0,0,12),NOP,NOP,ECALL],5)
add('faulting_store_suppresses_jal',[u(28,15),NOP,0x0ff0000f,NOP,s(2,28,0,0),j(7,12),NOP,NOP,ECALL],7)
add('loop_train_second',[i(0,1,0,9),i(0,2,0,0),i(0,3,0,7),i(0,4,0,8),i(0,1,1,-1),i(0,2,2,1),NOP,b(1,1,0,-12),ECALL])
try:
    (W/'manifest.txt').write_text('\n'.join(cases)+'\n')
    (W/'args.txt').write_text('--testplusarg MANIFEST=manifest.txt\n--testplusarg RESULTS=results.csv\n--testplusarg TRACE=retire.log\n')
    tb=(P/'sim/tb_core.sv').read_text().replace(".RESET_MTVEC(32'he000)",".M_ENABLE(1),.RESET_MTVEC(32'he000),"+parameters(CONFIGS['branch_pair']))
    tb=dualize_core_tb(tb,1)
    tb=tb.replace('    task automatic initialize_case;', '''    integer paired_controls=0,paired_jals=0;
    always @(posedge clk)if(!rst && checking && tv2)begin
        if(tinsn2[6:0]==7'h63)paired_controls=paired_controls+1;
        if(tinsn2[6:0]==7'h6f)paired_jals=paired_jals+1;
    end
    task automatic initialize_case;''')
    tb=tb.replace('        $display("REGRESSION_PASS', '''        if(paired_controls<10 || paired_jals==0)$fatal(1,"Branch pairing not exercised");
        $display("BRANCH_COVERAGE conditional=%0d jal=%0d",paired_controls,paired_jals);
        $display("REGRESSION_PASS''')
    (W/'tb.sv').write_text(tb)
    env=os.environ.copy();env['PROCESSOR_ARCHITECTURE']='AMD64';vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    run_command([vb/'xvlog.bat','-sv','-i',P/'rtl',*sorted((P/'rtl').glob('*.v')),W/'tb.sv'],W,W/'compile.log',env)
    run_command([vb/'xelab.bat','tb_core','-s','branch_directed'],W,W/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','branch_directed','-runall','-f','args.txt'],W,W/'simulate.log',env)
    assert f'REGRESSION_PASS cases={len(cases)}' in out and 'Fatal:' not in out,out[-5000:]
    rows=list(csv.DictReader((W/'results.csv').open()))
    state.update(status='passed',cases=len(cases),programs=programs,packets=sum(int(x['packets']) for x in rows),coverage=[x for x in out.splitlines() if 'BRANCH_COVERAGE' in x])
    print('BRANCH_DIRECTED_PASS',len(cases),flush=True)
except Exception as exc:state.update(status='failed',error=str(exc));raise
finally:
    for name in ('tb.sv','manifest.txt','results.csv','compile.log','elaborate.log','simulate.log'):
        if(W/name).exists():shutil.copy2(W/name,R/name)
    shutil.copytree(W/'cases',R/'cases',dirs_exist_ok=True)
    (R/'result.json').write_text(json.dumps(state,indent=2),encoding='utf-8')
