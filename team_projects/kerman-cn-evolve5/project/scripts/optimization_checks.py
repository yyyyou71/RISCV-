"""Independent multiplication oracle plus instruction-ROM protocol tests."""
import argparse,hashlib,json,os,random,re,sys
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command
sys.path.insert(0,str(PROJECT/'tests'))
from reference import Model

def multiply_check(folder):
    image=(folder/'firmware.bin').read_bytes()
    symbols=(folder/'firmware.symbols').read_text()
    pc=int(re.search(r'^([0-9a-f]+) T __mulsi3$',symbols,re.M)[1],16)
    edges=[0,1,2,3,7,0xff,0x100,0x7fff,0x8000,0xffff,0x10000,0x7fffffff,0x80000000,0x80000001,0xfffffffe,0xffffffff]
    pairs=[(a,b) for a in edges for b in edges]
    for bit in range(32):
        for edge in edges: pairs.extend(((1<<bit,edge),(edge,1<<bit)))
    rng=random.Random(20260926)
    pairs += [(rng.getrandbits(32),rng.getrandbits(32)) for _ in range(4096)]
    pairs += [(rng.randrange(-32768,32768)&0xffffffff,rng.randrange(-32768,32768)&0xffffffff) for _ in range(2048)]
    total=0; maximum=0
    preserved=[2,3,4,8,9,*range(18,28)]
    for a,b in pairs:
        model=Model(image,pc)
        model.reg=[(index*0x1234567)&0xffffffff for index in range(32)]
        model.reg[1]=0xe000; model.reg[2]=0xd000; model.reg[10]=a; model.reg[11]=b
        saved={index:model.reg[index] for index in preserved}
        count=0
        while model.pc!=0xe000:
            event=model.step(); count+=1
            if event['trap'] or count>1024: raise AssertionError(f'Helper trapped/timed out a={a:x} b={b:x}')
        if model.reg[10]!=(a*b)&0xffffffff: raise AssertionError(f'Multiply mismatch a={a:x} b={b:x}')
        if any(model.reg[index]!=value for index,value in saved.items()): raise AssertionError('Callee-saved ABI corruption')
        total+=count; maximum=max(maximum,count)
    return {'cases':len(pairs),'rv32i_model_instructions':total,'max_instructions_per_call':maximum,
            'oracle':'Python arbitrary-precision a*b modulo 2^32','callee_saved_registers_checked':preserved,
            'firmware_elf_sha256':hashlib.sha256((folder/'firmware.elf').read_bytes()).hexdigest()}

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--firmware-dir',type=Path,default=PROJECT/'reports/backend/coremark/c1_b1_w0_g0_bp1/firmware')
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work/cache3_checks')
    a=p.parse_args(); build=a.build_dir.resolve(); build.mkdir(parents=True,exist_ok=True)
    reports=PROJECT/'reports/optimization'; reports.mkdir(parents=True,exist_ok=True)
    state={'status':'running','started_utc':datetime.now(timezone.utc).isoformat()}
    manifest=reports/'checks.json'; manifest.write_text(json.dumps(state),encoding='utf-8')
    try:
        state['multiply']=multiply_check(a.firmware_dir)
        print('MULTIPLY_DIFFERENTIAL_PASS '+str(state['multiply']['cases']),flush=True)
        env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; vb=a.vivado/'bin'
        run_command([vb/'xvlog.bat','-sv',PROJECT/'rtl/soc/rv32_soc_memory.v',PROJECT/'sim/tb_rom_lookahead.sv'],build,reports/'rom_compile.log',env)
        run_command([vb/'xelab.bat','tb_rom_lookahead','-s','rom_lookahead','-mt','4'],build,reports/'rom_elaborate.log',env)
        out=run_command([vb/'xsim.bat','rom_lookahead','-runall'],build,reports/'rom_simulate.log',env)
        if 'ROM_LOOKAHEAD_PASS' not in out: raise RuntimeError(out[-6000:])
        state['rom_groups']=re.findall(r'LOOKAHEAD_CHECK (\S+)',out)
        state['rom_summary']=re.search(r'ROM_LOOKAHEAD_PASS[^\n]*',out)[0]
        state.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),
                     runtime_sha256=hashlib.sha256((PROJECT/'firmware/runtime.c').read_bytes()).hexdigest(),
                     memory_rtl_sha256=hashlib.sha256((PROJECT/'rtl/soc/rv32_soc_memory.v').read_bytes()).hexdigest(),
                     hardware_measurement=False)
        manifest.write_text(json.dumps(state,indent=2),encoding='utf-8')
        print('OPTIMIZATION_CHECKS_PASS',flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc)); manifest.write_text(json.dumps(state,indent=2),encoding='utf-8'); raise

if __name__=='__main__': main()
