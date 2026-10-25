"""Build the RV32I CoreMark port without changing EEMBC algorithm sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
from regress import PROJECT,run_command
from soc_regress import check_elf,ROM_BYTES

ALGORITHMS=['core_list_join.c','core_main.c','core_matrix.c','core_state.c','core_util.c','coremark.h']
UPSTREAM_COMMIT='b56889a7bd9d5624fbeff2a73ba69878e6a9c146'
DEFAULT_GCC=Path(r'D:\riscv\riscv64-unknown-elf-toolchain-10.2.0-2020.12.8-x86_64-w64-mingw32\bin\riscv64-unknown-elf-gcc.exe')
DEFAULT_BUILD=PROJECT.parents[1]/'work'/'evolve5_coremark_build'

def verify_algorithms():
    upstream=PROJECT/'third_party'/'coremark'
    expected={name:digest for digest,name in (line.split() for line in (upstream/'coremark.md5').read_text().splitlines())}
    checks={}
    for name in ALGORITHMS:
        data=(upstream/name).read_bytes()
        actual=hashlib.md5(data).hexdigest()
        if actual!=expected[name]: raise ValueError('Official source checksum mismatch: '+name)
        checks[name]={'md5':actual,'sha256':hashlib.sha256(data).hexdigest()}
    return checks

def build_coremark(build=DEFAULT_BUILD,gcc=DEFAULT_GCC,iterations=2048,software_isa='native',optimization='O2',extra_flags=()):
    if not 1<=iterations<=1000000: raise ValueError('Default iterations must be 1..1000000')
    build=build.resolve(); build.mkdir(parents=True,exist_ok=True)
    checks=verify_algorithms()
    folder=build/'firmware'/'coremark'; folder.mkdir(parents=True,exist_ok=True)
    fw=PROJECT/'firmware'; port=fw/'coremark_port'; vendor=PROJECT/'third_party'/'coremark'
    assert software_isa in ('native','software')
    arch='rv32im_zicsr2p0' if software_isa=='native' else 'rv32i_zicsr2p0'
    flags=['-march='+arch,'-mabi=ilp32','-mcmodel=medlow','-mno-relax','-msmall-data-limit=0',
           '-ffreestanding','-fno-builtin','-fno-strict-aliasing','-fno-pic','-fno-stack-protector','-fno-common',
           '-fno-asynchronous-unwind-tables','-fno-unwind-tables','-ffunction-sections','-fdata-sections',
           '-fno-tree-loop-distribute-patterns','-Wall','-Wextra','-Werror','-std=gnu11','-g','-'+optimization,
           '-DSOC_CLOCK_HZ=25000000u','-DSOC_UART_BAUD=115200u']
    flags+=list(extra_flags)
    printed=' '.join(flags)+'; link: -nostdlib --gc-sections --no-relax'
    config='#ifndef COREMARK_BUILD_CONFIG_H\n#define COREMARK_BUILD_CONFIG_H\n'
    config+=f'#define COREMARK_DEFAULT_ITERATIONS {iterations}u\n'
    config+='#define COREMARK_BUILD_ID "EVOLVE1_BOARD"\n'
    config+=f'#define COREMARK_NATIVE_M {int(software_isa=="native")}\n'
    config+='#define COREMARK_SOFTWARE_ISA "'+('RV32IM_Zicsr' if software_isa=='native' else 'RV32I_Zicsr')+'"\n'
    config+='#define COREMARK_FLAGS_TEXT '+json.dumps(printed)+'\n#endif\n'
    (folder/'coremark_build_config.h').write_text(config,encoding='ascii')
    include=['-I'+str(x) for x in (port,vendor,fw/'include',fw/'machine',folder)]
    startup=(fw/'crt0.S').read_text().replace('call main','call machine_init\n    call coremark_entry')
    (folder/'coremark_crt0.S').write_text(startup,encoding='ascii')
    sources=[folder/'coremark_crt0.S',fw/'drivers.c',fw/'runtime.c',fw/'platform.c',fw/'machine/machine.c',fw/'machine/trap_entry.S',port/'core_portme.c',port/'m_selfcheck.c',port/'dual_check.c',port/'dual_smoke.S']+[vendor/x for x in ALGORITHMS if x.endswith('.c')]
    env=os.environ.copy(); objects=[]
    for source in sources:
        obj=folder/(source.stem+'.o')
        run_command([gcc,*flags,*include,'-c',source,'-o',obj],build,folder/(source.stem+'.compile.log'),env)
        objects.append(obj)
    elf=folder/'firmware.elf'
    run_command([gcc,*flags,'-nostdlib','-nostartfiles',
                 '-Wl,--no-relax,--gc-sections','-Wl,-Map,'+str(folder/'firmware.map'),
                 '-T',fw/'link.ld',*objects,'-o',elf],build,folder/'link.log',env)
    tool=lambda name:str(gcc).replace('gcc.exe',name+'.exe')
    binary=folder/'firmware.bin'
    run_command([tool('objcopy'),'-O','binary',elf,binary],build,folder/'objcopy.log',env)
    run_command([tool('objdump'),'-d','-M','no-aliases',elf],build,folder/'firmware.dis',env)
    run_command([tool('nm'),'-n',elf],build,folder/'firmware.symbols',env)
    undefined=run_command([tool('nm'),'-u',elf],build,folder/'undefined.log',env)
    if undefined.strip(): raise RuntimeError('Unresolved symbols: '+undefined)
    image=binary.read_bytes()
    if len(image)>ROM_BYTES: raise RuntimeError('CoreMark does not fit the existing 32 KiB ROM')
    padded=image+bytes(ROM_BYTES-len(image))
    (folder/'firmware_rom.hex').write_text(''.join(f'{int.from_bytes(padded[n:n+4],"little"):08x}\n' for n in range(0,ROM_BYTES,4)),encoding='ascii')
    facts=check_elf(elf,allow_m=software_isa=='native')
    facts.update(app='coremark',optimization=optimization,image_bytes=len(image),clock_hz=25000000,baud=115200,
                 build_id='EVOLVE1_BOARD',software_isa=software_isa,extra_flags=list(extra_flags),
                 default_iterations=iterations,total_data_size=2000,contexts=1,
                 tick_unit='microseconds',precise_result_source='CM_RESULT raw 64-bit CPU-clock cycles',
                 flags=flags,printed_flags=printed,upstream_commit=UPSTREAM_COMMIT,algorithm_checksums=checks,
                 same_compilation_flags_for_all_sources=True,linked_prebuilt_libraries=False,
                 elf_sha256=hashlib.sha256(elf.read_bytes()).hexdigest(),
                 compiler=run_command([gcc,'--version'],build,folder/'compiler_version.log',env).splitlines()[0])
    (folder/'build.json').write_text(json.dumps(facts,indent=2),encoding='utf-8')
    print(f'COREMARK_BUILD_PASS bytes={len(image)} ISA={arch} instruction_words={facts["instruction_words_checked"]}',flush=True)
    return folder,facts

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--gcc',type=Path,default=DEFAULT_GCC)
    p.add_argument('--build-dir',type=Path,default=DEFAULT_BUILD); p.add_argument('--iterations',type=int,default=2048)
    p.add_argument('--software-isa',choices=('native','software'),default='native')
    p.add_argument('--optimization',choices=('O2','O3','Os'),default='O2')
    p.add_argument('--extra-flag',action='append',default=[])
    a=p.parse_args(); build_coremark(a.build_dir,a.gcc,a.iterations,a.software_isa,a.optimization,a.extra_flag)
