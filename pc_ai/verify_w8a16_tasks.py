#!/usr/bin/env python3
"""同一RV32I固件读取W8A16任务表，验证不同网络及错误恢复；期望值来自C。"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from pack_ai_model import pack_model, pack_run_request, words, BOOT_ADDR, align


def task_issues(t):
    if t[0]==2:
        return 0
    return t[10]*t[11]*(((t[7]&65535)+15)//16)*(((t[7]>>16)+3)//4)*(t[8]&3)**2*8


def generate(out,add_suite=False):
    specs = [json.loads((out/f'network{n}.json').read_text()) for n in range(3)]
    initial = {}
    expected = {}
    masks = {}
    cases = []
    launches = 0
    def emit(address, data, dest):
        assert address%16==0 and len(data)%16==0
        for off in range(0,len(data),16):
            dest[address+off] = int.from_bytes(data[off:off+16],'little')
    def package(index, base):
        p = pack_model(specs[index],base,root=out,output_fill=0xa7)
        for layer, output in enumerate(p.manifest['outputs']):
            data = (out/f'network{index}.layer{layer}.expected.bin').read_bytes()
            if len(data)!=output['bytes']:
                raise RuntimeError('C output size mismatch')
            p.golden[output['address']] = data
        return p
    def add(p, name, code=0, failed=0xffffffff, hw=0, completed=None, mutate=None):
        nonlocal launches
        raw = bytearray(p.data)
        if mutate:
            mutate(raw,p)
        emit(p.base,raw,initial)
        emit(p.base,raw,expected)
        completed = len(p.tasks) if completed is None else completed
        for t in p.tasks[:completed]:
            emit(t[4],p.golden[t[4]],expected)
        last = p.tasks[completed-1] if completed else [0]*16
        report = [code,failed,hw,completed,0,sum(task_issues(t) for t in p.tasks[:completed])&0xffffffff,last[10],last[11]]
        address = 0x4000+len(cases)*32
        emit(address,b'\xcc'*32,initial)
        emit(address,words(report),expected)
        masks[address+16] = ((1<<128)-1)^0xffffffff
        launches += completed+(code==6)
        cases.append(dict(name=name,model_addr=p.base,code=code,failed_task=failed,hardware_code=hw,completed=completed))
    good = [package(n,b) for n,b in enumerate((0x107a0,0x40000,0x60000) if add_suite else (0x107a0,0x20000,0x30000))]
    for n,p in enumerate(good):
        add(p,('real_bottleneck_residual','conv_add_conv_branch','two_add_layers')[n] if add_suite else
            ('two_real_convolutions','three_real_convolutions','grouped_branch_network')[n])
        (out/f'network{n}.model.bin').write_bytes(p.data)
        (out/f'network{n}.manifest.json').write_text(json.dumps(p.manifest,indent=2)+'\n')
    base = 0x80000 if add_suite else 0x40000
    def bad(name,code,index=0xffffffff,hw=0,completed=0,edit=None):
        nonlocal base
        p = package(2,base)
        base += 0x10000
        add(p,name,code,index,hw,completed,edit)
    def header(field,value):
        return lambda data,p: struct.pack_into('<I',data,field*4,value)
    def task(n,field,value):
        return lambda data,p: struct.pack_into('<I',data,64+n*64+field*4,value(p) if callable(value) else value)
    if add_suite:
        bad('unknown_opcode',3,0,edit=task(0,0,99))
        bad('wrong_channels',4,0,edit=task(0,7,(5<<16)|17))
        bad('zero_shape',4,0,edit=task(0,6,0))
        bad('unexpected_relu',4,0,edit=task(0,9,6))
        bad('conv_fields_in_add',4,0,edit=task(0,8,1))
        bad('bias_in_add',4,0,edit=task(0,3,16))
        bad('group_in_add',4,0,edit=task(0,12,16))
        bad('later_reserved_preflight',4,1,edit=task(1,13,1))
        bad('bad_output_shape',4,0,edit=task(0,10,99))
        bad('input_b_outside_arena',2,0,edit=task(0,2,0))
        bad('output_overwrites_a',2,1,edit=task(1,4,lambda p:p.tasks[1][1]))
        bad('output_overwrites_b',2,1,edit=task(1,4,lambda p:p.tasks[1][2]))
        bad('quant_in_work_area',2,0,edit=task(0,5,lambda p:p.tasks[0][4]))
        def invalid_add(n,offset,value):
            return lambda data,p:struct.pack_into('<I',data,p.tasks[n][5]-p.base+offset,value)
        bad('bad_mult_a',6,0,7,0,invalid_add(0,0,0x80000000))
        bad('bad_shift_a',6,0,7,0,invalid_add(0,4,64))
        bad('bad_mult_b',6,0,7,0,invalid_add(0,8,0x80000000))
        bad('bad_shift_b',6,0,7,0,invalid_add(0,12,64))
        bad('error_after_completed_add',6,1,7,1,invalid_add(1,4,64))
    else:
        add_conv_errors(bad,header,task)
    add(good[2],'recover_and_repeat_network')
    request = pack_run_request([c['model_addr'] for c in cases])
    for address,data in ((BOOT_ADDR,request[BOOT_ADDR:BOOT_ADDR+32]),(0x2000,request[0x2000:0x2000+len(cases)*16])):
        emit(address,data,initial)
        emit(address,data,expected)
    for name,data,digits in (('initial',initial,40),('golden',expected,72)):
        lines = []
        for address,value in sorted(data.items()):
            record = (address<<128)|value if name=='initial' else (address<<256)|(masks.get(address,(1<<128)-1)<<128)|value
            lines.append(f'{record:0{digits}x}\n')
        (out/(name+'.mem')).write_text(''.join(lines))
    (out/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    return dict(initial=len(initial),golden=len(expected),models=len(cases),launches=launches,
                valid_networks=3,invalid_models=sum(c['code']!=0 for c in cases))


def add_conv_errors(bad,header,task):
    bad('bad_magic',1,edit=header(0,0))
    bad('bad_version',1,edit=header(1,3))
    bad('reserved_flags',1,edit=header(13,3))
    bad('empty_task_table',1,edit=header(4,0))
    bad('wrong_task_size',1,edit=header(3,128))
    def old_format(data,p):
        struct.pack_into('<I',data,4,1)
        struct.pack_into('<I',data,13*4,0)
    bad('wrong_hardware_format',9,edit=old_format)
    bad('arena_overflow',2,edit=header(7,0x20000010))
    bad('task_count_multiply_overflow',2,edit=header(4,0xffffffff))
    bad('unknown_opcode',3,0,edit=task(0,0,99))
    bad('later_reserved_preflight',4,1,edit=task(1,13,1))
    bad('unaligned_group_split',4,0,edit=task(0,12,1))
    bad('group_split_outside_input',4,0,edit=task(0,12,32))
    bad('old_post_format',4,0,edit=task(0,9,1))
    bad('zero_shape',4,0,edit=task(0,6,0))
    bad('wrong_output_shape',4,0,edit=task(0,10,99))
    bad('output_overwrites_assets',2,1,edit=task(1,4,lambda p:p.tasks[1][2]))
    bad('quant_in_writable_area',2,0,edit=task(0,5,lambda p:p.tasks[0][4]))
    bad('quant_table_only_has_int8_size',2,0,edit=task(0,5,lambda p:p.header[12]-align(p.tasks[0][7]>>16,4)*16))
    bad('input_only_has_int8_size',2,0,edit=task(0,1,lambda p:p.header[7]-96))
    def invalid_quant(n,offset=0):
        return lambda data,p: struct.pack_into('<I',data,p.tasks[n][5]-p.base+offset,0x80000000)
    bad('engine_quant_error',6,0,7,0,invalid_quant(0))
    bad('engine_error_after_completed_layer',6,1,7,1,invalid_quant(1))
    bad('second_group_quant_error',6,0,7,0,invalid_quant(0,8))


def host_checks(out,run,add_suite=False):
    spec = json.loads((out/'network2.json').read_text())
    changes = [lambda s:s['layers'][0].update(input_b='missing'),lambda s:s['layers'][0].update(relu=True),
               lambda s:s['layers'][0].update(quant_add=[1,0,1]),lambda s:s['layers'][0]['quant_add'].__setitem__(0,1<<31),
               lambda s:s['layers'][0]['quant_add'].__setitem__(3,64)] if add_suite else [lambda s:s.update(activation_bits=9),lambda s:s['layers'][0].update(op='add'),
               lambda s:s['layers'][0].update(input='missing'),lambda s:s['layers'][0].update(group_split=1),
               lambda s:s['layers'][0].update(group_split=32),lambda s:s['layers'][0].update(quant_q13=[]),
               lambda s:s['layers'][0].update(output_int8=True),lambda s:s['layers'][0].update(quant=[[1,0]]*17),
               lambda s:s['layers'][0]['quant_q13'][0].__setitem__(0,1<<31),
               lambda s:s['layers'][0]['quant_q13'][0].__setitem__(5,96)]
    for change in changes:
        bad = deepcopy(spec)
        change(bad)
        try:
            pack_model(bad,root=out)
        except (ValueError,KeyError):
            pass
        else:
            raise RuntimeError('packer accepted incompatible W8A16 input')
    if add_suite:
        bad=json.loads((out/'network1.json').read_text());bad['layers'][4]['input_b']='layer3'
        try:pack_model(bad,root=out)
        except ValueError:pass
        else:raise RuntimeError('ADD accepted different channel shapes')
    try:
        pack_model(spec,root=out,reference=True)
    except ValueError:
        pass
    else:
        raise RuntimeError('unexpected independent Python W8A16 reference')
    # 检查文件的有符号INT16与内联整数完全一致，不引入第二套卷积计算。
    inline = deepcopy(spec)
    raw = (out/inline['input'].pop('data_file')).read_bytes()
    inline['input']['data'] = list(struct.unpack('<'+'h'*(len(raw)//2),raw))
    if pack_model(spec,root=out).data!=pack_model(inline,root=out).data:
        raise RuntimeError('INT16 input file packing mismatch')
    run(['python3',ROOT/'scripts/pack_ai_model.py',out/'network0.json','--base','0x107a0',
         '--output',out/'cli_model.bin','--request',out/'cli_request.bin'],'packer_cli')
    p = pack_model(json.loads((out/'network0.json').read_text()),0x107a0,root=out)
    if (out/'cli_model.bin').read_bytes()!=p.data or (out/'cli_request.bin').read_bytes()!=pack_run_request([p.base]):
        raise RuntimeError('W8A16 CLI package mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference',type=Path,default=ROOT.parent/'materials/TridentVision')
    parser.add_argument('--out',type=Path)
    parser.add_argument('--suite',choices=('conv','add'),default='conv',help='add同时验证ADD单元、DDR和残差任务网络')
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--profiles',choices=('normal','all'),default='normal')
    args = parser.parse_args()
    add_suite=args.suite=='add'
    out = (args.out or ROOT/('pc_ai/outputs/add_tasks' if add_suite else 'pc_ai/outputs/w8a16_tasks')).resolve()
    out.mkdir(parents=True,exist_ok=True)
    ref = args.reference.resolve()
    def run(command,name,cwd=None):
        directory=out if cwd is None else cwd
        try:
            r = subprocess.run([str(x) for x in command],cwd=directory,capture_output=True,text=True,timeout=120)
        except subprocess.TimeoutExpired as error:
            (directory/(name+'.log')).write_bytes((error.stdout or b'')+(error.stderr or b''))
            raise RuntimeError(name+' timed out') from error
        content = r.stdout+r.stderr
        (directory/(name+'.log')).write_text(content)
        if r.returncode:
            raise RuntimeError(name+' failed:\n'+content[-5000:])
        return content
    if add_suite:
        (out/'ddr').mkdir(exist_ok=True)
    run(['gcc','-O2','-std=c11','-DTRIDENT_SOURCE='+json.dumps(str(ref/'training/export/rearch_fixed.c')),
         '-I',ref/'c_model',ROOT/('pc_ai/export_add_tasks.c' if add_suite else 'pc_ai/export_w8a16_tasks.c'),
         '-lm','-o',out/'export_vectors'],'compile_c')
    run([out/'export_vectors',ref/'training/export/rearch_int8.bin'],'export_c')
    counts = generate(out,add_suite)
    host_checks(out,run,add_suite)
    add_counts={}
    if add_suite:
        add_counts=json.loads((out/'add_counts.json').read_text())
        run(['iverilog','-g2012','-s','TB_add_int16','-o',out/'unit.vvp',ROOT/'Iverilog/TB_add_int16.v',ROOT/'vsrc/add_int16.v'],'compile_unit')
        run(['iverilog','-g2012','-s','TB_conv2d_ddr_engine','-y',ROOT/'vsrc','-DDDR3_MODEL_SLOTS=8192',
             '-PTB_conv2d_ddr_engine.QUANT_TEST=3','-o',out/'ddr/test.vvp',ROOT/'Iverilog/TB_conv2d_ddr_engine.v',ROOT/'vsrc/ddr3.sv'],'compile_ddr')
        run(['verilator','--lint-only','-Wall','--top-module','add_int16',ROOT/'vsrc/add_int16.v'],'lint_unit')
        run(['verilator','--lint-only','-Wall','-Wno-TIMESCALEMOD','-Wno-SYNCASYNCNET','--top-module','peripheral_bus',
             '-GENABLE_DDR=1','-GENABLE_AI=1','-GAI_ACT_WIDTH=16','-y',ROOT/'vsrc',ROOT/'vsrc/peripheral_bus.v'],'lint_add_bus')
    lib = subprocess.check_output(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-print-libgcc-file-name'],text=True).strip()
    run(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-msmall-data-limit=0','-ffreestanding',
         '-nostdlib','-nostartfiles','-Os','-Wall','-Wextra','-Werror','-fstack-usage','-T',ROOT/'link.ld',
         '-Wl,-Map='+str(out/'runner.map'),'-o',out/'runner.elf',ROOT/'asm/start.s',
         ROOT/'csrc/software/ai_task_runner.c',ROOT/'csrc/software/ai_runtime.c',lib],'build')
    for section,name in (('.text','runner.bin'),('.data','runner.data.bin')):
        run(['riscv64-unknown-elf-objcopy','-j',section,'-O','binary',out/'runner.elf',out/name],name)
    code = (out/'runner.bin').read_bytes()
    data = (out/'runner.data.bin').read_bytes()
    if len(code)>32768 or len(data)>65536:
        raise RuntimeError('runtime does not fit ROM/RAM')
    (out/'runner.hex').write_text(''.join(f'{int.from_bytes(code[n:n+4],"little"):08x}\n' for n in range(0,len(code),4)))
    (out/'runner.data').write_text(''.join(f'{b:02x}\n' for b in data) or '00\n')
    for width,name in ((16,'test.vvp'),(8,'width8.vvp')):
        run(['iverilog','-g2012','-s','TB_ddr_cpu_window','-y',ROOT/'vsrc','-I',ROOT/'Iverilog',
             '-DDDR3_MODEL_SLOTS=32768','-DAI_TASK_PROGRAM','-PTB_ddr_cpu_window.CPU_TEST=1',
             '-PTB_ddr_cpu_window.AI_ENABLE=1',f'-PTB_ddr_cpu_window.AI_ACT_WIDTH={width}',
             f'-DPROG_FILE="{out/"runner.hex"}"',f'-DDATA_FILE="{out/"runner.data"}"',
             '-o',out/name,ROOT/'Iverilog/TB_ddr_cpu_window.v',ROOT/'vsrc/ddr3.sv'],'compile_'+str(width))
    if args.prepare_only:
        print(f'已准备{counts["models"]}次模型请求、{counts["launches"]}次AI提交，ROM={len(code)}字节。')
        print('去掉 --prepare-only 开始仿真；--profiles all 增加非整数时钟比和DDR停顿配置。')
        return
    results = {}
    if add_suite:
        checks=[('unit',[out/'unit.vvp',f'+COUNT={add_counts["unit_vectors"]}'],out)]
        for name,options in (('normal',[]),('stalled',['+ddr3_random_stalls=1']),
                             ('zero_latency',['+ddr3_read_latency=0','+ddr3_write_latency=0'])):
            checks.append(('ddr_'+name,[out/'ddr/test.vvp',f'+JOBS={add_counts["layers"]}',
                f'+INITIAL={add_counts["initial"]}',f'+GOLDEN={add_counts["golden"]}',*options],out/'ddr'))
        for name,command,directory in checks:
            log=run(['vvp',*command],name,directory)
            summaries=[line for line in log.splitlines() if line.startswith('PASS ')]
            if len(summaries)!=1:raise RuntimeError('missing ADD PASS: '+name)
            print(name+': '+summaries[0],flush=True);results[name]=summaries[0]
    profiles = {'cpu25':[]}
    if args.profiles=='all':
        profiles.update(cpu71_ddr166_stalled=['+cpu_half_ns=7','+ddr3_core_period_ns=6','+ddr3_random_stalls=1'],
                        cpu166_ddr80_zero=['+cpu_half_ns=3','+ddr3_core_period_ns=12.5','+ddr3_read_latency=0','+ddr3_write_latency=0'])
    for name,options in profiles.items():
        log = run(['vvp',out/'test.vvp',f'+TASK_INITIAL={counts["initial"]}',f'+TASK_GOLDEN={counts["golden"]}',
                   f'+TASK_JOBS={counts["models"]}',f'+TASK_LAUNCHES={counts["launches"]}',*options],name)
        summaries = [line for line in log.splitlines() if line.startswith('PASS ')]
        if len(summaries)!=1:
            raise RuntimeError('missing task PASS')
        print(name+': '+summaries[0],flush=True)
        results[name] = summaries[0]
    # 原生故障不能被当作可恢复的参数错误：报告写回也必须停止。
    original = (out/'golden.mem').read_text()
    initial = (out/'initial.mem').read_text().splitlines()
    try:
        (out/'golden.mem').write_text(''.join(f'{((int(line,16)>>128)<<256)|(((1<<128)-1)<<128)|(int(line,16)&((1<<128)-1)):072x}\n' for line in initial))
        log = run(['vvp',out/'test.vvp',f'+TASK_INITIAL={counts["initial"]}',f'+TASK_GOLDEN={counts["initial"]}',
                   f'+TASK_JOBS={counts["models"]}','+TASK_LAUNCHES=1','+TASK_REPORTS=0',
                   '+TASK_EXPECT_EXIT=517','+TASK_INJECT_FAULT=1'],'native_fault')
        summaries = [line for line in log.splitlines() if line.startswith('PASS ')]
        if len(summaries)!=1:
            raise RuntimeError('missing fault PASS')
        print('native_fault: '+summaries[0],flush=True)
        results['native_fault'] = summaries[0]
    finally:
        (out/'golden.mem').write_text(original)
    # 同一固件用于8位RTL，版本2包应在任何AI提交之前拒绝。
    initial_text = (out/'initial.mem').read_text()
    try:
        image = {int(line,16)>>128:int(line,16)&((1<<128)-1) for line in initial_text.splitlines()}
        first_model = json.loads((out/'cases.json').read_text())[0]['model_addr']
        request = pack_run_request([first_model])
        for address,length in ((BOOT_ADDR,32),(0x2000,16)):
            for off in range(0,length,16):
                image[address+off] = int.from_bytes(request[address+off:address+off+16],'little')
        (out/'initial.mem').write_text(''.join(f'{(a<<128)|v:040x}\n' for a,v in sorted(image.items())))
        wanted = image.copy()
        report = words([9,0xffffffff,0,0,0,0,0,0])
        for off in (0,16):
            wanted[0x4000+off] = int.from_bytes(report[off:off+16],'little')
        (out/'golden.mem').write_text(''.join(f'{(a<<256)|(((1<<128)-1)<<128)|v:072x}\n' for a,v in sorted(wanted.items())))
        log = run(['vvp',out/'width8.vvp',f'+TASK_INITIAL={len(image)}',f'+TASK_GOLDEN={len(wanted)}',
                   '+TASK_JOBS=1','+TASK_LAUNCHES=0'],'wrong_width8')
        summaries = [line for line in log.splitlines() if line.startswith('PASS ')]
        if len(summaries)!=1:
            raise RuntimeError('missing reverse format rejection PASS')
        print('wrong_width8: '+summaries[0],flush=True)
        results['wrong_width8'] = summaries[0]
    finally:
        (out/'initial.mem').write_text(initial_text)
        (out/'golden.mem').write_text(original)
    (out/'result.json').write_text(json.dumps(dict(passed=True,**counts,rom_bytes=len(code),data_bytes=len(data),
        firmware_sha256=hashlib.sha256(code).hexdigest(),profiles=args.profiles,results=results,
        golden_source='original C conv_layer/add_point' if add_suite else 'original C conv_layer',
        suite=args.suite,add_tests=add_counts,full_detection_network=False,pds_verified=False),indent=2)+'\n')


if __name__=='__main__':
    main()
