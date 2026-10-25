"""Build freestanding RV32I C firmware and run bus + pin-level SoC tests."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess
import sys
import time
from regress import PROJECT,run_command

ROM_BYTES=32768
MASK=0xffffffff


def s32(x):
    return x-0x100000000 if x & 0x80000000 else x


def arithmetic_header(path):
    pairs=[(0,1),(1,1),(MASK,1),(MASK,MASK),(0x80000000,1),
           (0x80000000,MASK),(MASK,0x80000000),(0x12345678,7),
           (MASK,3),(0x7fffffff,0xfffffff9)]
    rng=random.Random(20260922)
    while len(pairs)<64: pairs.append((rng.getrandbits(32),rng.getrandbits(32) or 1))
    lines=['#ifndef ARITHMETIC_VECTORS_H','#define ARITHMETIC_VECTORS_H','#include <stdint.h>',
           '#define ARITH_COUNT 64u',
           'struct arithmetic_vector { uint32_t a,b,product,quotient,remainder; int32_t sa,sb,signed_quotient,signed_remainder; };',
           'static const struct arithmetic_vector arith[ARITH_COUNT] = {']
    for a,b in pairs:
        sa,sb=s32(a),s32(b)
        if sa == -2147483648 and sb == -1: sb=3
        q=abs(sa)//abs(sb)
        if (sa<0)!=(sb<0): q=-q
        vals=[a,b,(a*b)&MASK,a//b,a%b,sa,sb,q,sa-q*sb]
        fields=[f'0x{x & MASK:08x}u' if n<5 else f'(int32_t)0x{x & MASK:08x}u' for n,x in enumerate(vals)]
        lines.append('    {'+','.join(fields)+'},')
    lines+=['};','#endif','']
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text('\n'.join(lines),encoding='ascii')


def is_rv32i(w):
    op=w&127; f3=(w>>12)&7; f7=w>>25
    if op in (0x37,0x17,0x6f): return True
    if op==0x67: return f3==0
    if op==0x63: return f3 in (0,1,4,5,6,7)
    if op==0x03: return f3 in (0,1,2,4,5)
    if op==0x23: return f3 in (0,1,2)
    if op==0x13: return (f3!=1 or f7==0) and (f3!=5 or f7 in (0,32))
    if op==0x33: return f7==0 or (f7==32 and f3 in (0,5))
    if op==0x0f: return f3==0
    return w in (0x73,0x100073,0x30200073,0x10500073) or (op==0x73 and f3 in (1,2,3,5,6,7))


def check_elf(path,intentional_faults=None,allow_m=False):
    data=path.read_bytes()
    if data[:6]!=b'\x7fELF\x01\x01': raise ValueError('Expected ELF32 little-endian')
    hdr=struct.unpack_from('<HHIIIIIHHHHHH',data,16)
    etype,machine,version,entry,phoff,shoff,flags,ehsize,phsize,phnum,shsize,shnum,shstr=hdr
    if machine!=243 or entry!=0 or flags&1: raise ValueError('Wrong machine/entry or compressed-instruction flag')
    sections=[struct.unpack_from('<IIIIIIIIII',data,shoff+n*shsize) for n in range(shnum)]
    names=data[sections[shstr][4]:sections[shstr][4]+sections[shstr][5]]
    info=[]; instructions=0
    for sec in sections:
        name=names[sec[0]:].split(b'\0',1)[0].decode()
        if name in ('.text','.rodata','.data','.bss'):
            info.append({'name':name,'address':sec[3],'bytes':sec[5]})
        if sec[2]&4: # SHF_EXECINSTR: check every actual instruction word
            if sec[5]%4: raise ValueError(f'Non-word-sized code section {name}')
            for offset in range(0,sec[5],4):
                word=struct.unpack_from('<I',data,sec[4]+offset)[0]
                legal_m=allow_m and word&127==0x33 and word>>25==1
                if not (is_rv32i(word) or legal_m) and (sec[3]+offset,word) not in (intentional_faults or set()):
                    raise ValueError(f'Unsupported instruction at {sec[3]+offset:08x}: {word:08x}')
                instructions+=1
    return {'elf_class':32,'machine':machine,'entry':entry,'rvc_flag':False,'instruction_words_checked':instructions,'isa':('RV32IM_Zicsr' if allow_m else 'RV32I_Zicsr')+' plus MRET/WFI','sections':info}


def build_firmware(app,opt,gcc,build,env,clock_hz=50000000,baud=115200):
    name=app+'_'+opt
    folder=build/'firmware'/name
    folder.mkdir(parents=True,exist_ok=True)
    fw=PROJECT/'firmware'
    flags=['-march=rv32i','-mabi=ilp32','-mcmodel=medlow','-mno-relax','-msmall-data-limit=0',
           '-ffreestanding','-fno-builtin','-fno-pic','-fno-stack-protector','-fno-common',
           '-fno-asynchronous-unwind-tables','-fno-unwind-tables','-ffunction-sections','-fdata-sections',
           '-fno-tree-loop-distribute-patterns','-Wall','-Wextra','-Werror','-std=gnu11','-g','-'+opt,
           f'-DSOC_CLOCK_HZ={clock_hz}u',f'-DSOC_UART_BAUD={baud}u','-I'+str(fw/'include'),'-I'+str(fw/'generated')]
    objects=[]
    for source in [fw/'crt0.S',fw/'drivers.c',fw/'runtime.c',fw/'apps'/(app+'.c')]:
        obj=folder/(source.stem+'.o')
        run_command([gcc,*flags,'-c',source,'-o',obj],build,folder/(source.stem+'.compile.log'),env)
        objects.append(obj)
    elf=folder/'firmware.elf'
    run_command([gcc,'-march=rv32i','-mabi=ilp32','-nostdlib','-nostartfiles',
                 '-Wl,--no-relax,--gc-sections','-Wl,-Map,'+str(folder/'firmware.map'),
                 '-T',fw/'link.ld',*objects,'-o',elf],build,folder/'link.log',env)
    binary=folder/'firmware.bin'
    tool=lambda name: str(gcc).replace('gcc.exe',name+'.exe')
    run_command([tool('objcopy'),'-O','binary',elf,binary],build,folder/'objcopy.log',env)
    dis=run_command([tool('objdump'),'-d','-M','no-aliases',elf],build,folder/'firmware.dis',env)
    syms=run_command([tool('nm'),'-n',elf],build,folder/'firmware.symbols',env)
    undefined=run_command([tool('nm'),'-u',elf],build,folder/'undefined.log',env)
    if undefined.strip(): raise RuntimeError('Unresolved firmware symbols: '+undefined)
    image=binary.read_bytes()
    if len(image)>ROM_BYTES: raise RuntimeError('Firmware exceeds ROM')
    padded=image+bytes(ROM_BYTES-len(image))
    (folder/'firmware_rom.hex').write_text(''.join(f'{int.from_bytes(padded[n:n+4],"little"):08x}\n' for n in range(0,ROM_BYTES,4)),encoding='ascii')
    facts=check_elf(elf)
    facts.update(app=app,optimization=opt,image_bytes=len(image),gcc_flags=flags,clock_hz=clock_hz,baud=baud,
                 linked_prebuilt_libraries=False,unresolved_symbols=0,
                 elf_sha256=hashlib.sha256(elf.read_bytes()).hexdigest())
    (folder/'build.json').write_text(json.dumps(facts,indent=2),encoding='utf-8')
    return folder,facts


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--gcc',type=Path,default=Path(r'D:\riscv\riscv64-unknown-elf-toolchain-10.2.0-2020.12.8-x86_64-w64-mingw32\bin\riscv64-unknown-elf-gcc.exe'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work'/'cache3_soc')
    p.add_argument('--only',choices=['all','peripherals','firmware'],default='all')
    a=p.parse_args()
    build=a.build_dir.resolve(); build.mkdir(parents=True,exist_ok=True)
    reports=PROJECT/'reports'/'soc'; reports.mkdir(parents=True,exist_ok=True)
    state={'status':'running','scope':a.only,'started_utc':datetime.now(timezone.utc).isoformat()}
    latest=reports/'latest_run.json'; latest.write_text(json.dumps(state,indent=2),encoding='utf-8')
    env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'
    start=time.monotonic()
    try:
        arithmetic_header(PROJECT/'firmware'/'generated'/'arithmetic_vectors.h')
        (build/'unit_rom.hex').write_text('11223344\n55667788\n'+'00000000\n'*(8192-2),encoding='ascii')
        vb=a.vivado/'bin'
        sources=sorted((PROJECT/'rtl').rglob('*.v'))
        run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sources,PROJECT/'sim'/'tb_soc.sv',PROJECT/'sim'/'tb_soc_peripherals.sv'],build,build/'compile.log',env)
        if a.only in ('all','peripherals'):
            run_command([vb/'xelab.bat','tb_soc_peripherals','-s','soc_peripherals','-debug','typical','-mt','4'],build,build/'peripherals_elaborate.log',env)
            out=run_command([vb/'xsim.bat','soc_peripherals','-runall'],build,build/'peripherals.log',env)
            if 'PERIPHERALS_PASS' not in out: raise RuntimeError('Peripheral tests failed\n'+out[-5000:])
            state['peripheral_groups']=re.findall(r'PERIPHERAL_CHECK (\S+)',out)
            for n in ('compile.log','peripherals_elaborate.log','peripherals.log'): shutil.copy2(build/n,reports/n)
        if a.only in ('all','firmware'):
            run_command([vb/'xelab.bat','tb_soc','-s','soc_firmware','-debug','typical','-mt','4'],build,build/'soc_elaborate.log',env)
            apps=[]
            for app,opt in [('selftest','O0'),('selftest','O2'),('echo','O2'),('fault_rom','O2')]:
                folder,facts=build_firmware(app,opt,a.gcc,build,env)
                shutil.copy2(folder/'firmware_rom.hex',build/'firmware_rom.hex')
                (build/'soc.args').write_text('--testplusarg APP='+app+'\n',encoding='ascii')
                sim_args=[vb/'xsim.bat','soc_firmware','-f','soc.args']
                if app=='selftest' and opt=='O2':
                    # Pin-level evidence, without logging every RAM bit or CPU clock edge.
                    wave=reports/'soc_io.vcd'
                    tcl='open_vcd {'+wave.as_posix()+'}\n'
                    for signal in ('rst','uart_rx','uart_tx','gpio_out','gpio_oe','timer_pending','halted'):
                        tcl+='log_vcd [get_objects /tb_soc/'+signal+']\n'
                    tcl+='run all\nclose_vcd\nquit\n'
                    (build/'capture_io.tcl').write_text(tcl,encoding='utf-8')
                    sim_args+=['-onfinish','stop','-tclbatch','capture_io.tcl']
                else: sim_args+=['-runall']
                out=run_command(sim_args,build,folder/'simulate.log',env,timeout=600)
                if 'SOC_PASS' not in out: raise RuntimeError('SoC firmware failed\n'+out[-6000:])
                facts['simulation_result']=(build/'soc_result.txt').read_text().strip()
                facts['uart_text']=(build/'uart.txt').read_text(encoding='ascii')
                dest=reports/(app+'_'+opt); dest.mkdir(exist_ok=True)
                for path in folder.iterdir():
                    if path.is_file() and path.suffix!='.o': shutil.copy2(path,dest/path.name)
                for n in ('uart.txt','soc_result.txt','boot_trace.csv'): shutil.copy2(build/n,dest/n)
                apps.append(facts)
                print('PASS '+app+' '+opt+': '+facts['simulation_result'],flush=True)
            state['firmware']=apps
            shutil.copy2(build/'soc_elaborate.log',reports/'soc_elaborate.log')
        hashes={}
        for folder in ('rtl','firmware','scripts','sim'):
            for path in sorted((PROJECT/folder).rglob('*')):
                if path.is_file() and '__pycache__' not in path.parts:
                    hashes[path.relative_to(PROJECT).as_posix()]=hashlib.sha256(path.read_bytes()).hexdigest()
        state.update(status='passed',completed_utc=datetime.now(timezone.utc).isoformat(),
                     elapsed_seconds=round(time.monotonic()-start,2),source_sha256=hashes,
                     python=sys.version,simulator=str(a.vivado),
                     limits=['Simulation only; no PDS implementation or board validation',
                             'These baseline C apps leave machine interrupts masked; separate machine demo exercises MTIP',
                             'Runtime supports required 32-bit integer helpers; not a complete C standard library'])
        latest.write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
        print('SOC_REGRESSION_PASS '+a.only,flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc))
        latest.write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8')
        raise


if __name__=='__main__': main()
