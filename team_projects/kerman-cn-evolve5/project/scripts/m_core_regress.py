from pathlib import Path
import sys,os,struct,json,random,shutil,csv,argparse
from regress import PROJECT,run_command
from build_coremark import DEFAULT_GCC
sys.path.insert(0,str(PROJECT/'tests'))
from m_reference import MModel,NAMES
from reference import pack
from generate import r,i,s,b,u,image,ECALL,write_image,random_image
from front_configs import CONFIGS,parameters
from dual_testbench import dualize_core_tb

p=argparse.ArgumentParser();p.add_argument('--config',choices=CONFIGS,default='baseline');args=p.parse_args()
build=PROJECT.parents[1]/'work'/('evolve5_core_'+args.config); report=PROJECT/'reports/m_core'/args.config
build.mkdir(exist_ok=True); report.mkdir(parents=True,exist_ok=True); (build/'cases').mkdir(exist_ok=True)
state={'status':'running','hardware_tested':False}; manifest=report/'result.json'; manifest.write_text(json.dumps(state))
def li(rd,x): return [u(rd,((x+0x800)>>12)&0xfffff),i(0,rd,rd,x&4095)]
try:
    cases=[]; programs=[]; coverage={}
    def add(name,binary,cause=11,reset=0,upstream=False):
        model=MModel(binary); trace=model.run(); trace[-1]['next_pc']=0xe000
        assert trace[-1]['cause']==cause,(name,trace[-1])
        if upstream: assert model.reg[3]==1,name
        for k,v in model.coverage.items(): coverage[k]=coverage.get(k,0)+v
        write_image(build/'cases'/f'{name}.hex',binary)
        (build/'cases'/f'{name}.gold').write_text(''.join(pack(row)+'\n' for row in trace))
        for im,dm in ((0,0),(1,1),(2,2),(0,3)):
            cases.append(f'{name}_i{im}d{dm} cases/{name}.hex cases/{name}.gold {len(trace)} {im} {dm} 20261018 {reset}')
        programs.append({'name':name,'retirement_packets':len(trace),'cause':cause,'upstream':upstream})
    edges=[0,1,2,7,31,0x7fffffff,0x80000000,0x80000001,0xfffffffe,0xffffffff,0x12345678]
    vectors=[(op,a,c) for a in edges for c in edges for op in range(8)]
    for chunk in range(0,len(vectors),96):
        words=[u(28,8)]
        for op,a,c in vectors[chunk:chunk+96]:
            words+=li(1,a)+li(2,c)+[r(op,3,1,2,1),r(0,4,3,3),s(2,28,4,0),i(2,5,28,0,3),r(op,6,5,2,1),r(op,0,1,2,1)]
        words+=[ECALL]; add(f'edges_{chunk//96:02d}',image(words))
    words=li(1,0x81234567)+li(2,13)
    for op in range(8): words += [r(op,1,1,2,1),r((op+3)%8,2,1,2,1),r(0,3,1,2)]
    add('rd_source_alias',image(words+[ECALL]))
    add('wrong_path_multiply_divide',image(li(1,99)+li(2,7)+[b(0,0,0,12),r(5,7,1,2,1),r(0,8,1,2,1),i(0,9,0,11),ECALL]))
    add('older_load_fault_cancels_divide',image(li(1,0x7fffffff)+li(2,7)+[u(28,15),i(2,6,28,0,3),r(5,7,1,2,1),r(0,8,7,1),ECALL]),5)
    add('older_store_fault_cancels_multiply',image(li(1,0x81234567)+li(2,7)+[u(28,15),s(2,28,1,0),r(1,7,1,2,1),ECALL]),7)
    add('reset_during_divide',image(li(1,0x81234567)+li(2,7)+[r(5,3,1,2,1),r(0,4,3,2,1),ECALL]),reset=2)
    add('reset_during_multiply',image(li(1,0x81234567)+li(2,7)+[r(2,3,1,2,1),r(0,4,3,2,1),ECALL]),reset=2)
    add('m_encoding_reserved',image(li(1,123)+[r(0,1,1,1,3),ECALL]),2)
    words=li(28,0x8000)+li(1,0x80ff8001)+[s(2,28,1,0)]
    for f3,offset in ((0,0),(0,1),(0,2),(0,3),(1,0),(1,2),(2,0),(4,1),(4,3),(5,0),(5,2)):
        words += [i(f3,5,28,offset,3),r(0,6,5,5),i(f3,7,28,offset,3),b(0,7,5,8),i(0,9,0,99),
                  i(f3,8,28,offset,3),s(2,28,8,4),i(f3,10,28,offset,3),r(0,11,10,1,1),
                  i(f3,0,28,offset,3),r(0,12,0,5)]
    add('load_signed_unsigned_use_branch_store_m_x0',image(words+[ECALL]))
    words=li(28,0x8000)
    # Store the target PC, then immediately load it and consume it in JALR.
    target=(len(words)+2+4)*4
    words+=li(1,target)+[s(2,28,1,0),i(2,5,28,0,3),i(0,6,5,0,0x67),i(0,9,0,99),i(0,10,0,77),ECALL]
    add('load_to_jalr',image(words))
    for seed in range(12):
        raw=bytearray(random_image(0x90100000+seed,500)); rng=random.Random(seed)
        for off in range(0,0x8000,4):
            word=int.from_bytes(raw[off:off+4],'little')
            if word==ECALL: break
            if word&127==0x33 and rng.randrange(4)!=0: struct.pack_into('<I',raw,off,(word&0x1ffffff)|(1<<25))
        add(f'random_mixed_{seed:02d}',bytes(raw))
    # Bring in the matching upstream M test bodies; all test macros/harness stay local.
    vendor=PROJECT/'third_party/riscv-tests'
    for name in ('rv32um','rv64um'):
        assert (vendor/'isa'/name).is_dir(),'Missing bundled upstream M test bodies'
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'
    for source in sorted((vendor/'isa/rv32um').glob('*.S')):
        elf=build/'cases'/('upstream_'+source.stem+'.elf'); binary=elf.with_suffix('.bin')
        run_command([DEFAULT_GCC,'-march=rv32im_zicsr2p0','-mabi=ilp32','-mno-relax','-nostdlib','-nostartfiles','-I'+str(PROJECT/'tests/env'),'-I'+str(vendor/'isa/macros/scalar'),'-Wl,--no-relax','-T',PROJECT/'tests/env/link.ld',source,'-o',elf],build,elf.with_suffix('.compile.log'),env)
        run_command([str(DEFAULT_GCC).replace('gcc.exe','objcopy.exe'),'-O','binary',elf,binary],build,elf.with_suffix('.objcopy.log'),env)
        add('upstream_'+source.stem,binary.read_bytes(),upstream=True)
    assert set(NAMES)<=coverage.keys()
    (build/'manifest.txt').write_text('\n'.join(cases)+'\n')
    (build/'args.txt').write_text('--testplusarg MANIFEST=manifest.txt\n--testplusarg RESULTS=results.csv\n--testplusarg TRACE=retire.log\n')
    tb=(PROJECT/'sim/tb_core.sv').read_text().replace('.RESET_MTVEC(32\'he000)',".M_ENABLE(1),.RESET_MTVEC(32'he000)")
    tb=tb.replace(".M_ENABLE(1)",'.M_ENABLE(1),'+parameters(CONFIGS[args.config]))
    tb=dualize_core_tb(tb,CONFIGS[args.config]['wide_fetch'])
    tb=tb.replace('if (warm_reset != 0) begin','''if(warm_reset==2) begin
                    while(!dut.md_issued && wait_cycles<1000) begin @(posedge clk); #1; wait_cycles=wait_cycles+1; end
                    if(!dut.md_issued) $fatal(1,"Reset never reached M operation");
                    initialize_case();
                end
                if (warm_reset == 1) begin''')
    tb=tb.replace('if (halted || dut.csrfile.mepc', 'if(dut.md_valid || !dut.md_ready || dut.md_issued) $fatal(1,"M operation survived trap drain");\n                if (halted || dut.csrfile.mepc')
    (build/'tb_m_core.sv').write_text(tb)
    vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sorted((PROJECT/'rtl').glob('*.v')),build/'tb_m_core.sv'],build,build/'compile.log',env)
    run_command([vb/'xelab.bat','tb_core','-s','mcore','-mt','4'],build,build/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','mcore','-runall','-f','args.txt'],build,build/'simulate.log',env,timeout=1200)
    assert f'REGRESSION_PASS cases={len(cases)}' in out and 'Fatal:' not in out
    for fn in ('manifest.txt','results.csv','compile.log','elaborate.log','simulate.log','tb_m_core.sv'): shutil.copy2(build/fn,report/fn)
    state.update(status='passed',config=args.config,programs=programs,cases=len(cases),instruction_coverage=coverage,oracle='Independent Python arithmetic + complete architectural retirement comparison + eight upstream rv32um tests')
    manifest.write_text(json.dumps(state,indent=2)); print('M_CORE_PASS',len(cases),flush=True)
except Exception as e:
    state.update(status='failed',error=str(e)); manifest.write_text(json.dumps(state,indent=2)); raise
