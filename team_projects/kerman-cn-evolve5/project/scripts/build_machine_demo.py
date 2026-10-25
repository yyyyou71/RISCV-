import argparse,json,os,re
from pathlib import Path
from regress import PROJECT,run_command
from build_coremark import DEFAULT_GCC
from soc_regress import check_elf,ROM_BYTES

def build_demo(build,gcc=DEFAULT_GCC):
    build=build.resolve(); build.mkdir(parents=True,exist_ok=True)
    fw=PROJECT/'firmware'; folder=build/'firmware/machine_demo'; folder.mkdir(parents=True,exist_ok=True)
    flags=['-march=rv32i_zicsr2p0','-mabi=ilp32','-mcmodel=medlow','-mno-relax','-msmall-data-limit=0',
           '-ffreestanding','-fno-builtin','-fno-strict-aliasing','-fno-pic','-fno-stack-protector','-fno-common',
           '-fno-asynchronous-unwind-tables','-fno-unwind-tables','-ffunction-sections','-fdata-sections',
           '-fno-tree-loop-distribute-patterns','-Wall','-Wextra','-Werror','-std=gnu11','-g','-O2',
           '-DSOC_CLOCK_HZ=25000000u','-DSOC_UART_BAUD=115200u']
    include=['-I'+str(fw/'include'),'-I'+str(fw/'machine')]
    startup=(fw/'crt0.S').read_text().replace('call main','call machine_init\n    call main')
    (folder/'machine_crt0.S').write_text(startup,encoding='ascii')
    sources=[folder/'machine_crt0.S',fw/'drivers.c',fw/'runtime.c',fw/'platform.c',fw/'machine/cache_probe.S',fw/'machine/machine.c',fw/'machine/trap_entry.S',fw/'machine/probes.S',fw/'apps/machine_demo.c']
    env=os.environ.copy(); objects=[]
    for source in sources:
        obj=folder/(source.stem+'.o'); objects.append(obj)
        run_command([gcc,*flags,*include,'-c',source,'-o',obj],build,folder/(source.stem+'.compile.log'),env)
    elf=folder/'firmware.elf'
    run_command([gcc,'-march=rv32i_zicsr2p0','-mabi=ilp32','-nostdlib','-nostartfiles','-Wl,--no-relax,--gc-sections',
                 '-Wl,-Map,'+str(folder/'firmware.map'),'-T',fw/'link.ld',*objects,'-o',elf],build,folder/'link.log',env)
    tool=lambda name:str(gcc).replace('gcc.exe',name+'.exe')
    run_command([tool('objcopy'),'-O','binary',elf,folder/'firmware.bin'],build,folder/'objcopy.log',env)
    run_command([tool('objdump'),'-d','-M','no-aliases',elf],build,folder/'firmware.dis',env)
    symbols=run_command([tool('nm'),'-n',elf],build,folder/'firmware.symbols',env)
    undefined=run_command([tool('nm'),'-u',elf],build,folder/'undefined.log',env); assert not undefined.strip()
    illegal_pc=int(re.search(r'^([0-9a-f]+) T probe_illegal_fault$',symbols,re.M)[1],16)
    facts=check_elf(elf,{(illegal_pc,0xffffffff)})
    image=(folder/'firmware.bin').read_bytes(); assert len(image)<=ROM_BYTES
    padded=image+bytes(ROM_BYTES-len(image))
    (folder/'firmware_rom.hex').write_text(''.join(f'{int.from_bytes(padded[i:i+4],"little"):08x}\n' for i in range(0,ROM_BYTES,4)),encoding='ascii')
    facts.update(app='machine_demo',build_id='CACHE3_BOARD',clock_hz=25000000,baud=115200,image_bytes=len(image),
                 intentional_illegal_instruction={'address':illegal_pc,'word':'ffffffff','purpose':'Recoverable illegal-instruction test'},
                 flags=flags,hardware_tested=False)
    (folder/'build.json').write_text(json.dumps(facts,indent=2),encoding='utf-8')
    print('MACHINE_DEMO_BUILD_PASS '+str(len(image)),flush=True)
    return folder,facts

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--gcc',type=Path,default=DEFAULT_GCC)
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work/cache3_demo_build')
    args=p.parse_args(); build_demo(args.build_dir,args.gcc)
