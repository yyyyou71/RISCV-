#!/usr/bin/env python3
"""同一 RV32I 固件与同一 RTL，读取 DDR 任务表执行不同网络及异常用例。"""
import sys
sys.dont_write_bytecode = True
from copy import deepcopy
import json
from pathlib import Path
import random
import struct
import subprocess
from pack_ai_model import pack_model, pack_run_request, words, BOOT_ADDR

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/ai_tasks'


def run(args,log):
    try:
        r=subprocess.run([str(x) for x in args],cwd=OUT,capture_output=True,text=True,timeout=120)
    except subprocess.TimeoutExpired as error:
        (OUT/log).write_bytes((error.stdout or b'')+(error.stderr or b''))
        raise RuntimeError(f'{log} timeout') from error
    content=r.stdout+r.stderr;(OUT/log).write_text(content)
    if r.returncode:raise RuntimeError(f'{log}\n{content[-5000:]}')
    return content


def specs():
    rng=random.Random(0xA1AB12026)
    def network(shape,layers):
        spec=dict(input=dict(shape=list(shape),data=[rng.randrange(-16,17) for _ in range(shape[0]*shape[1]*shape[2])]),layers=[])
        shapes={'input':shape}
        for n,(co,k,s,p,relu,int8,source) in enumerate(layers):
            source=source or ('input' if n==0 else f'layer{n-1}')
            h,w,ci=shapes[source]
            layer=dict(name=f'layer{n}',input=source,op='conv2d',out_channels=co,kernel=k,stride=s,padding=p,
                bias_enable=True,weights=[rng.randrange(-5,6) for _ in range(co*k*k*ci)],
                biases=[rng.randrange(-19,20) for _ in range(co)],relu=relu,output_int8=int8)
            if int8:layer['quant']=[[rng.choice([1,3,7]),rng.choice([3,4,5])] for _ in range(co)]
            spec['layers'].append(layer);shapes[f'layer{n}']=((h+2*p-k)//s+1,(w+2*p-k)//s+1,co)
        return spec
    return [network((3,5,17),[(5,3,1,1,True,True,None),(3,1,2,0,False,True,None)]),
            network((4,6,3),[(17,1,1,0,True,True,None),(6,3,2,1,False,True,None),(3,1,1,0,False,False,None)]),
            network((2,3,2),[(3,1,1,0,True,True,None),(2,3,1,1,True,True,None),(1,1,1,0,False,True,'layer0')])]


def issues(task):
    ci=task[7]&65535;co=task[7]>>16;k=task[8]&3
    return task[10]*task[11]*((ci+15)//16)*((co+3)//4)*k*k*8


def generate():
    networks=specs()
    initial={};expected={};masks={};cases=[];launches=0
    def emit(address,data,into):
        assert address%16==0 and len(data)%16==0
        for off in range(0,len(data),16):into[address+off]=int.from_bytes(data[off:off+16],'little')
    def add(package,label,code=0,failed=0xffffffff,hardware=0,completed=None,mutate=None):
        nonlocal launches
        raw=bytearray(package.data)
        if mutate:mutate(raw,package)
        emit(package.base,raw,initial);emit(package.base,raw,expected)
        completed=len(package.tasks) if completed is None else completed
        for task in package.tasks[:completed]:emit(task[4],package.golden[task[4]],expected)
        total_issues=sum(issues(t) for t in package.tasks[:completed])&0xffffffff
        last=package.tasks[completed-1] if completed else [0]*16
        report=[code,failed,hardware,completed,0,total_issues,last[10],last[11]]
        report_addr=0x4000+len(cases)*32
        emit(report_addr,b'\xcc'*32,initial);emit(report_addr,words(report),expected)
        masks[report_addr+16]=((1<<128)-1)^0xffffffff # cycles 由测试台按真实任务计数逐项核对
        launches+=completed+(code==6)
        cases.append(dict(name=label,model_addr=package.base,code=code,failed_task=failed,
                          hardware_code=hardware,completed=completed))
    # 第一条 64 字节任务跨越 DDR 的 2 KiB 列边界。
    good=[pack_model(s,base,reference=True,output_fill=0xa7) for s,base in zip(networks,[0x107a0,0x20000,0x30000])]
    for p,name in zip(good,['two_layers','three_layers_raw_final','branch_reuses_earlier_tensor']):add(p,name)
    base=0x40000
    def bad(label,code,index=0xffffffff,hw=0,completed=0,edit=None):
        nonlocal base
        p=pack_model(networks[0],base,reference=True,output_fill=0xa7);base+=0x10000
        add(p,label,code,index,hw,completed,edit)
    def header(field,value):return lambda data,p:struct.pack_into('<I',data,field*4,value)
    def task(n,field,value):return lambda data,p:struct.pack_into('<I',data,64+n*64+field*4,value(p) if callable(value) else value)
    bad('bad_magic',1,edit=header(0,0))
    bad('bad_version',1,edit=header(1,2))
    bad('reserved_header',1,edit=header(13,1))
    bad('empty_task_table',1,edit=header(4,0))
    bad('wrong_task_size',1,edit=header(3,128))
    bad('arena_overflow',2,edit=header(7,0x20000010))
    bad('task_count_multiply_overflow',2,edit=header(4,0xffffffff))
    bad('unknown_opcode',3,0,edit=task(0,0,99))
    bad('later_bad_reserved_preflight',4,1,edit=task(1,12,1))
    bad('zero_shape',4,0,edit=task(0,6,0))
    bad('illegal_activation',4,0,edit=task(0,9,2))
    bad('wrong_output_shape',4,0,edit=task(0,10,99))
    bad('output_overwrites_assets',2,1,edit=task(1,4,lambda p:p.tasks[1][2]))
    bad('output_overlaps_input',2,1,edit=task(1,4,lambda p:p.tasks[1][1]))
    bad('quant_in_writable_area',2,0,edit=task(0,5,lambda p:p.tasks[0][4]))
    def bad_quant(n):return lambda data,p:struct.pack_into('<I',data,p.tasks[n][5]-p.base,0x80000000)
    bad('engine_quant_error',6,0,7,0,bad_quant(0))
    bad('engine_error_after_completed_layer',6,1,7,1,bad_quant(1))
    # 再执行已经运行过的网络，不共同复位、不重新加载固件或改变 RTL。
    # 同一包重复运行只更新预期报告，不能把初始值再覆盖到第一次执行前的黄金结果。
    add(good[0],'recover_and_rerun_same_model')
    request_image=pack_run_request([c['model_addr'] for c in cases])
    request=request_image[BOOT_ADDR:BOOT_ADDR+32]
    listing=request_image[0x2000:0x2000+len(cases)*16]
    emit(BOOT_ADDR,request,initial);emit(BOOT_ADDR,request,expected)
    emit(0x2000,listing,initial);emit(0x2000,listing,expected)
    for name,data,digits in [('initial',initial,40),('golden',expected,72)]:
        lines=[]
        for address,value in sorted(data.items()):
            record=(address<<128)|value if name=='initial' else (address<<256)|(masks.get(address,(1<<128)-1)<<128)|value
            lines.append(f'{record:0{digits}x}\n')
        (OUT/(name+'.mem')).write_text(''.join(lines))
    for index,(spec,p) in enumerate(zip(networks,good)):
        (OUT/f'network{index}.json').write_text(json.dumps(spec,indent=2)+'\n')
        (OUT/f'network{index}.bin').write_bytes(p.data)
        (OUT/f'network{index}.manifest.json').write_text(json.dumps(p.manifest,indent=2)+'\n')
    (OUT/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    return len(initial),len(expected),len(cases),launches


def host_checks():
    # 拒绝无法由当前通路表达的输入；不给不兼容网络静默补默认数值规则。
    base_spec=specs()[0]
    for change in [lambda s:s['layers'][0].update(op='add'),lambda s:s['layers'][0].update(input='missing'),
                   lambda s:s['layers'][0].update(quant=[]),lambda s:s['layers'][0].update(weights=[128]),
                   lambda s:s['layers'][0].update(output_int8=False,relu=False)]:
        spec=deepcopy(base_spec);change(spec)
        try:pack_model(spec)
        except (ValueError,KeyError):pass
        else:raise RuntimeError('packer accepted incompatible graph')
    for base in [1,0x10001,0x20000000]:
        try:pack_model(base_spec,base)
        except ValueError:pass
        else:raise RuntimeError('packer accepted invalid base')
    for addresses in [[],[0x10000]*65,[1],[0x20000000]]:
        try:pack_run_request(addresses)
        except ValueError:pass
        else:raise RuntimeError('packer accepted invalid run request')
    # 外部文件与内联整数必须生成完全相同的包，不能发生字节序或有符号转换差异。
    directory=OUT/'file_inputs';directory.mkdir(exist_ok=True)
    file_spec=deepcopy(base_spec)
    for item,key,file_key,width,name in [(file_spec['input'],'data','data_file',8,'image')]+[
            (layer,key,key+'_file',width,f'layer{n}_{key}') for n,layer in enumerate(file_spec['layers'])
            for key,width in [('weights',8),('biases',32)]]:
        values=item.pop(key);path=directory/(name+'.bin')
        path.write_bytes(struct.pack('<'+('b' if width==8 else 'i')*len(values),*values))
        item[file_key]=path.name
    if pack_model(file_spec,root=directory).data!=pack_model(base_spec).data:raise RuntimeError('external data packing mismatch')


def main():
    OUT.mkdir(parents=True,exist_ok=True);host_checks()
    initial,golden,jobs,launches=generate()
    lib=subprocess.check_output(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-print-libgcc-file-name'],text=True).strip()
    run(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-msmall-data-limit=0','-ffreestanding',
         '-nostdlib','-nostartfiles','-Os','-Wall','-Wextra','-Werror','-fstack-usage','-T',ROOT/'link.ld',
         '-Wl,-Map='+str(OUT/'runner.map'),'-o',OUT/'runner.elf',ROOT/'asm/start.s',
         ROOT/'csrc/software/ai_task_runner.c',ROOT/'csrc/software/ai_runtime.c',lib],'build.log')
    for section,name in [('.text','runner.bin'),('.data','runner.data.bin')]:
        run(['riscv64-unknown-elf-objcopy','-j',section,'-O','binary',OUT/'runner.elf',OUT/name],name+'.log')
    code=(OUT/'runner.bin').read_bytes();data=(OUT/'runner.data.bin').read_bytes()
    if len(code)>32768 or len(data)>65536:raise RuntimeError('firmware does not fit ROM/RAM')
    (OUT/'runner.hex').write_text(''.join(f'{int.from_bytes(code[n:n+4],"little"):08x}\n' for n in range(0,len(code),4)))
    (OUT/'runner.data').write_text(''.join(f'{x:02x}\n' for x in data) or '00\n')
    run(['iverilog','-g2012','-s','TB_ddr_cpu_window','-y',ROOT/'vsrc','-I',ROOT/'Iverilog',
         '-DDDR3_MODEL_SLOTS=16384','-DAI_TASK_PROGRAM','-PTB_ddr_cpu_window.CPU_TEST=1','-PTB_ddr_cpu_window.AI_ENABLE=1',
         f'-DPROG_FILE="{OUT/"runner.hex"}"',f'-DDATA_FILE="{OUT/"runner.data"}"',
         '-o',OUT/'test.vvp',ROOT/'Iverilog/TB_ddr_cpu_window.v',ROOT/'vsrc/ddr3.sv'],'compile.log')
    results={}
    profiles={'cpu25':[], 'cpu50_stalled':['+cpu_half_ns=10','+ddr3_random_stalls=1','+ddr3_stall_every=7','+ddr3_stall_cycles=2'],
              'cpu25_zero_latency':['+ddr3_read_latency=0','+ddr3_write_latency=0']}
    for name,options in profiles.items():
        output=run(['vvp',OUT/'test.vvp',f'+TASK_INITIAL={initial}',f'+TASK_GOLDEN={golden}',
                    f'+TASK_JOBS={jobs}',f'+TASK_LAUNCHES={launches}',*options],name+'.log')
        summaries=[s for s in output.splitlines() if s.startswith('PASS ')]
        if len(summaries)!=1:raise RuntimeError('missing task runner PASS')
        print(name+': '+summaries[0],flush=True);results[name]=summaries[0]
    # 请求区有错时不能发起任何 AI 任务或写出报告；原生故障时也不能假装继续。
    valid_initial=(OUT/'initial.mem').read_text();valid_golden=(OUT/'golden.mem').read_text()
    initial_words={int(line,16)>>128:int(line,16)&((1<<128)-1) for line in valid_initial.splitlines()}
    rejects=[('bad_request_magic',BOOT_ADDR,0,0x101),('too_many_jobs',BOOT_ADDR+8,65,0x101),
             ('reserved_request',BOOT_ADDR+28,1,0x101),('wrapped_list_address',BOOT_ADDR+12,0xfffffff0,0x102),
             ('overlapping_reports',BOOT_ADDR+16,0x2000,0x102),('unaligned_list',BOOT_ADDR+12,0x2001,0x102),
             ('reserved_list_entry',0x2004,1,0x101),('native_fault',None,None,0x205)]
    try:
        for name,address,value,exit_code in rejects:
            image=initial_words.copy()
            if address is not None:
                base=address&~15;shift=(address&15)*8
                image[base]=(image[base]&~(0xffffffff<<shift))|(value<<shift)
            (OUT/'initial.mem').write_text(''.join(f'{((a<<128)|v):040x}\n' for a,v in sorted(image.items())))
            (OUT/'golden.mem').write_text(''.join(f'{((a<<256)|(((1<<128)-1)<<128)|v):072x}\n' for a,v in sorted(image.items())))
            output=run(['vvp',OUT/'test.vvp',f'+TASK_INITIAL={initial}',f'+TASK_GOLDEN={initial}',
                f'+TASK_JOBS={jobs}',f'+TASK_LAUNCHES={int(address is None)}','+TASK_REPORTS=0',
                f'+TASK_EXPECT_EXIT={exit_code}',f'+TASK_INJECT_FAULT={int(address is None)}'],name+'.log')
            summaries=[s for s in output.splitlines() if s.startswith('PASS ')]
            if len(summaries)!=1:raise RuntimeError('missing rejection PASS')
            print(name+': '+summaries[0],flush=True);results[name]=summaries[0]
    finally:
        (OUT/'initial.mem').write_text(valid_initial);(OUT/'golden.mem').write_text(valid_golden)
    # 真正执行命令行入口并核对相同输入的二进制输出，供外部装载流程复用。
    run(['python3',ROOT/'scripts/pack_ai_model.py',OUT/'network0.json','--base','0x107a0',
         '--output',OUT/'cli_model.bin','--request',OUT/'cli_request.bin','--reference'],'packer_cli.log')
    expected=pack_model(json.loads((OUT/'network0.json').read_text()),0x107a0,reference=True)
    if (OUT/'cli_model.bin').read_bytes()!=expected.data:raise RuntimeError('CLI package mismatch')
    if (OUT/'cli_request.bin').read_bytes()!=pack_run_request([expected.base]):raise RuntimeError('CLI run request mismatch')
    (OUT/'result.json').write_text(json.dumps(dict(rom_bytes=len(code),data_bytes=len(data),models=jobs,
        launches=launches,checked_words=golden,results=results),indent=2)+'\n')
    print(f'RV32I runtime ROM={len(code)} data={len(data)} bytes; same firmware/RTL for all models')


if __name__=='__main__':main()
