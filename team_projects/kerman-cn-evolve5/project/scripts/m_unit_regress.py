from pathlib import Path
import sys,json,random,os,shutil,re
from regress import PROJECT,run_command
sys.path.insert(0,str(PROJECT/'tests')); from m_reference import result
build=PROJECT.parents[1]/'work/evolve5_unit'; report=PROJECT/'reports/m_unit'
build.mkdir(exist_ok=True); report.mkdir(parents=True,exist_ok=True)
state={'status':'running','hardware_tested':False}; manifest=report/'result.json'; manifest.write_text(json.dumps(state))
try:
    edges=[0,1,2,3,7,16,31,0x7fffffff,0x80000000,0x80000001,0xfffffffe,0xffffffff,0x12345678,0xa5a5a5a5]
    pairs=[(a,b) for a in edges for b in edges]; rng=random.Random(20261018)
    pairs += [(rng.getrandbits(32),rng.getrandbits(32)) for _ in range(2048)]
    vectors=[(op,a,b,result(op,a,b)) for a,b in pairs for op in range(8)]
    (build/'m_vectors.txt').write_text(''.join(f'{op} {a:08x} {b:08x} {v:08x}\n' for op,a,b,v in vectors))
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=Path(r'D:\Vivado_2025\2025.2\Vivado\bin')
    tb=(PROJECT/'sim/tb_muldiv.sv').read_text().replace('parameter FAST=0;','parameter FAST=1;').replace('rv32_muldiv dut(','rv32_muldiv #(.FAST_MUL(FAST)) dut(')
    (build/'tb_muldiv.sv').write_text(tb,encoding='utf-8')
    run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/rv32_muldiv.v',build/'tb_muldiv.sv'],build,build/'compile.log',env)
    run_command([vb/'xelab.bat','tb_muldiv','-s','muldiv','-mt','4'],build,build/'elaborate.log',env)
    out=run_command([vb/'xsim.bat','muldiv','-runall'],build,build/'simulate.log',env)
    assert f'MULDIV_UNIT_PASS vectors={len(vectors)} cancellation_cases=48' in out and 'Fatal:' not in out
    for n in ('m_vectors.txt','compile.log','elaborate.log','simulate.log'): shutil.copy2(build/n,report/n)
    state.update(status='passed',vectors=len(vectors),cancellation_cases=48,operations=8,response_backpressure_cycles='0..7',oracle='Python arbitrary-precision arithmetic')
    manifest.write_text(json.dumps(state,indent=2)); print('MULDIV_UNIT_VERIFIED',len(vectors),flush=True)
except Exception as e:
    state.update(status='failed',error=str(e)); manifest.write_text(json.dumps(state,indent=2)); raise
