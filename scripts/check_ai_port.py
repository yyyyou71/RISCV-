"""Short Acore single/dual + W8A16/DDR regression; never runs the full network."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/ai-port'


def run(command,name,cwd=OUT,timeout=180):
    started=time.monotonic()
    with (cwd/(name+'.log')).open('w') as log:
        result=subprocess.run(list(map(str,command)),cwd=cwd,stdout=log,
                              stderr=subprocess.STDOUT,timeout=timeout)
    text=(cwd/(name+'.log')).read_text()
    if result.returncode:
        raise RuntimeError(f'{name}: {text[-4500:]}')
    return text,time.monotonic()-started


def compile_sim(bench,name,parameters,defines,jobs):
    excluded={'ROM_core.v','memory_core.v','multiplier_core.v','acore_fetch_memory.v',
        'multiply_adder.v','multiply_adder_w8a16.v','video_async_fifo.v','MuxKeyInternal.v'}
    rtl=[p for p in sorted((ROOT/'rtl').glob('*.v')) if p.name not in excluded]
    rtl+=sorted((ROOT/'sim/models').glob('*.v'))
    destination=OUT/(name+'_obj')
    run(['verilator','--binary','--timing','--assert','--no-sched-zero-delay',
        '-Wno-fatal','-Wno-TIMESCALEMOD','--top-module',bench,'-j',jobs,
        '--Mdir',destination,'-o','check',
        '-I'+str(ROOT/'sim/ai'),'-DDDR3_MODEL_SLOTS=32768','-DDDR3_MODEL_STRICT_READS',*parameters,*defines,
        ROOT/'sim/ai'/ (bench+'.v'),ROOT/'sim/ddr3/ddr3.sv',*rtl],name+'_compile')
    return destination/'check'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference',type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--postprocess-metadata',type=Path,
                        help='Optional heads.json from model preparation; run a single-convolution CPU detection check')
    args=parser.parse_args()
    if args.jobs<1:parser.error('jobs must be positive')
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/'ddr').mkdir(exist_ok=True)
    sys.path[:0]=[str(ROOT/'scripts'),str(ROOT/'pc_ai')]
    import verify_w8a16_tasks as fixtures
    reference=args.reference.resolve()
    run(['gcc','-O2','-std=c11','-DTRIDENT_SOURCE='+json.dumps(str(reference/'training/export/rearch_fixed.c')),
        '-I',reference/'c_model',ROOT/'pc_ai/export_upsample_tasks.c','-lm','-o',OUT/'export_vectors'], 'compile_reference')
    run([OUT/'export_vectors',reference/'training/export/rearch_int8.bin'],'export_short_fixtures')
    counts=fixtures.generate(OUT,up_suite=True)
    lib=subprocess.check_output(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32',
        '-print-libgcc-file-name'],text=True).strip()
    run(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-msmall-data-limit=0',
        '-mno-relax','-ffreestanding','-fno-builtin','-nostdlib','-nostartfiles','-Os',
        '-Wall','-Wextra','-Werror','-fstack-usage','-T',ROOT/'firmware/ai_link.ld',
        '-Wl,-Map=runner.map','-o','runner.elf',ROOT/'firmware/start.S',
        ROOT/'csrc/software/ai_task_runner.c',ROOT/'csrc/software/ai_runtime.c',lib], 'firmware')
    for section,output in [('.text','runner.bin'),('.data','runner.data.bin')]:
        run(['riscv64-unknown-elf-objcopy','-j',section,'-O','binary','runner.elf',output],output)
    code=(OUT/'runner.bin').read_bytes();data=(OUT/'runner.data.bin').read_bytes()
    if len(code)>32768 or len(data)>49152:raise ValueError('Firmware exceeds ROM/RAM with 16 KiB stack reserve')
    (OUT/'runner.hex').write_text(''.join(f'{int.from_bytes(code[n:n+4],"little"):08x}\n' for n in range(0,len(code),4)))
    (OUT/'runner.data').write_text(''.join(f'{v:02x}\n' for v in data) or '00\n')
    records=[]
    def check(name,binary,options):
        text,elapsed=run([binary,*options],name)
        summaries=[line for line in text.splitlines() if line.startswith('PASS ')]
        if len(summaries)!=1:raise RuntimeError(name+' missing PASS')
        records.append(dict(name=name,summary=summaries[0],simulation_seconds=elapsed,
            plusargs=options,passed=True))
        print(name+': '+summaries[0],flush=True)
    defines=['-DAI_TASK_PROGRAM','-DPROG_FILE="runner.hex"','-DDATA_FILE="runner.data"']
    options=[f'+TASK_INITIAL={counts["initial"]}',f'+TASK_GOLDEN={counts["golden"]}',
        f'+TASK_JOBS={counts["models"]}',f'+TASK_LAUNCHES={counts["launches"]}']
    for dual in (0,1):
        binary=compile_sim('TB_ddr_cpu_window','tasks_'+str(dual),
            ['-GCPU_TEST=1','-GAI_ENABLE=1','-GAI_ACT_WIDTH=16',f'-GENABLE_DUAL={dual}'],defines,args.jobs)
        check(f'tasks_dual{dual}_cpu25',binary,options)
        check(f'tasks_dual{dual}_stalled',binary,options+['+cpu_half_ns=7',
            '+ddr3_core_period_ns=6','+ddr3_random_stalls=1'])
    # Four-state native fault, reset-in-flight and simultaneous IIC/AI access.
    run(['iverilog','-g2012','-s','TB_ai_control','-y',ROOT/'sim/models','-y',ROOT/'rtl',
        '-DDDR3_MODEL_SLOTS=8192','-o','control.vvp',ROOT/'sim/ai/TB_ai_control.v',
        ROOT/'sim/ddr3/ddr3.sv'],'control_compile')
    check('fault_reset_mmio_coexist','vvp',[str(OUT/'control.vvp')])
    run(['iverilog','-g2012','-s','TB_ddr_unknown_write','-DDDR3_MODEL_SLOTS=16',
        '-o','unknown.vvp',ROOT/'sim/ai/TB_ddr_unknown_write.v',ROOT/'sim/ddr3/ddr3.sv'], 'unknown_compile')
    negative=subprocess.run(['vvp',str(OUT/'unknown.vvp')],cwd=OUT,capture_output=True,text=True,timeout=10)
    text=negative.stdout+negative.stderr
    (OUT/'unknown_rejection.log').write_text(text)
    if not negative.returncode or 'PASS masked unknown' not in text or 'DDR3: unknown enabled write byte' not in text:
        raise RuntimeError('Four-state unknown-write rejection failed: '+text)
    records.append(dict(name='four_state_unknown_write',passed=True,expected_failure=True,
        summary='Known enabled byte accepted despite masked X; enabled X byte rejected'))
    if args.postprocess_metadata:
        from verify_ai_postprocess import combined_check
        from postprocess_tools import build_tools
        metadata=json.loads(args.postprocess_metadata.resolve().read_text())
        postdir=OUT/'postprocess_smoke';postdir.mkdir(exist_ok=True)
        post=combined_check(postdir/'combined',metadata,build_tools(postdir,reference))
        dest=ROOT/'reports/ai_port/postprocess.json';dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_text(json.dumps(post,indent=2)+'\n')
        records.append(dict(name='dual_cpu_detection',passed=True,summary=
            f'One RTL convolution, {post["checked_words"]} DDR words, {post["postprocess"]["count"]} CPU detection records'))
    files=sorted((ROOT/'rtl').glob('*.v'))+sorted((ROOT/'sim/models').glob('*.v'))
    files+=sorted((ROOT/'sim/ai').glob('*'))+[Path(__file__).resolve(),ROOT/'sim/ddr3/ddr3.sv',
        ROOT/'csrc/software/ai_runtime.c',ROOT/'csrc/software/ai_task_runner.c',ROOT/'firmware/ai_link.ld',ROOT/'firmware/start.S']
    result=dict(passed=True,**counts,cases=records,rom_bytes=len(code),data_bytes=len(data),
        firmware_sha256=hashlib.sha256(code).hexdigest(),full_network_run=False,
        coremark_run=False,vendor_ip_verified=False,pds_implemented=False,
        verilator=subprocess.check_output(['verilator','--version'],text=True).strip(),
        source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    destination=ROOT/'reports/ai_port/short_checks.json'
    destination.parent.mkdir(parents=True,exist_ok=True)
    destination.write_text(json.dumps(result,indent=2)+'\n')
    print('PASS: short port checks; report '+str(destination),flush=True)


if __name__=='__main__':main()
