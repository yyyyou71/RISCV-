#!/usr/bin/env python3
"""导出TridentVision全网任务；默认不推理，--golden/--run供用户启动长任务。"""
import sys
sys.dont_write_bytecode=True
import argparse
from collections import Counter
import csv
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from pack_ai_model import pack_model,pack_run_request,words,align,BOOT_ADDR
from verify_w8a16_tasks import task_issues


def sha(data):return hashlib.sha256(data).hexdigest()
def dump(path,value):path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')
def checked(condition,message):
    if not condition:raise ValueError(message)


def run(command,directory,name,env=None):
    # 完整C推理/RTL仿真仅在用户显式指定相应参数后调用，不设短命令超时。
    with (directory/(name+'.log')).open('w') as log:
        process=subprocess.Popen([str(x) for x in command],cwd=directory,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env)
        for line in process.stdout:
            log.write(line);log.flush()
            if name=='export' or name.startswith('run'):print(line,end='',flush=True)
        code=process.wait()
    if code:raise RuntimeError(name+'失败，见 '+str(directory/(name+'.log')))
    return (directory/(name+'.log')).read_text()


def audit(package,graph):
    """用通用打包器的形状/地址与C导出图互检，并统计实际资产大小。"""
    nodes=graph['nodes'];tasks=package.tasks;outputs=package.manifest['outputs']
    checked(len(nodes)==len(tasks)==99,'整网任务数不是99')
    checked(Counter(n['op'] for n in nodes)==dict(conv2d=72,add=10,concat=14,maxpool5=1,upsample2x=2),'算子数量不符')
    assets=[];macs=0
    for i,(n,t,o) in enumerate(zip(nodes,tasks,outputs)):
        checked(n['index']==i and n['shape']==o['shape'] and n['op']==o['op'],'C/打包器输出形状不符')
        sources=[n['a']]+([n['b']] if t[0] in (2,3) else [])
        for field,source in zip((1,2),sources):
            checked(-1<=source<i,'图未按拓扑顺序排列')
            address=package.header[8] if source<0 else outputs[source]['address']
            checked(t[field]==address,'分支输入地址不符')
        ci=t[7]&65535;co=t[7]>>16;regions=[]
        if t[0]==1:
            k=t[8]&3;regions=[('weights',t[2],align(co,4)*k*k*align(ci)),('bias',t[3],align(co,4)*4),('quant',t[5],align(co,4)*32)]
            macs+=t[10]*t[11]*ci*co*k*k
        elif t[0]==2:regions=[('add_quant',t[5],16)]
        for kind,address,size in regions:
            checked(package.base<=address<address+size<=package.header[12],'只读资产越界')
        assets.append(regions)
    reached=set()
    def visit(index):
        if index<0 or index in reached:return
        reached.add(index);visit(nodes[index]['a'])
        if nodes[index]['op'] in ('add','concat'):visit(nodes[index]['b'])
    for head in graph['heads']:
        visit(head['box_node']);visit(head['cls_node'])
    checked(len(reached)==99,'存在不属于六张检测输出的孤立任务')
    by_kind=Counter()
    for rs in assets:
        for kind,_,size in rs:by_kind[kind]+=size
    features=sum(o['bytes'] for o in outputs)
    memory=dict(by_kind,input=package.header[9],header_and_tasks=64+99*64,features=features,guards=99*32)
    checked(sum(memory.values())==len(package.data),'模型内存统计不一致')
    return assets,dict(tasks=99,operators=dict(Counter(n['op'] for n in nodes)),logical_macs=macs,
        mac_issues=sum(task_issues(t) for t in tasks),memory_bytes=memory,model_bytes=len(package.data),
        ddr_bytes=0x20000000,arena_begin=package.header[6],readonly_end=package.header[12],arena_end=package.header[7])


def save_layout(out,package,graph,summary):
    heads=[]
    for head in graph['heads']:
        entry=dict(head)
        for field in ('box','cls'):
            index=head[field+'_node'];o=package.manifest['outputs'][index]
            entry[field]=dict(node=index,name=graph['nodes'][index]['name'],address=o['address'],bytes=o['bytes'],shape=o['shape'])
        heads.append(entry)
    dump(out/'heads.json',dict(schema=1,format='HWC-align16(C), signed little-endian INT16',
        engine_input_shape=graph['input_shape'],heads=heads,sigmoid_y=graph['sigmoid_y'],sigmoid_dy=graph['sigmoid_dy'],
        postprocess_implemented_in_cpu=False,header_final_output_is_only_last_cls=True))
    with (out/'tasks.csv').open('w',newline='') as f:
        writer=csv.writer(f);writer.writerow(['index','name','op','source_a','source_b','H','W','C','input_addr','input_b_or_weight','output_addr','output_bytes'])
        for n,t,o in zip(graph['nodes'],package.tasks,package.manifest['outputs']):
            writer.writerow([n['index'],n['name'],n['op'],n['a'],n['b'],*n['shape'],f'0x{t[1]:08x}',f'0x{t[2]:08x}',f'0x{t[4]:08x}',o['bytes']])
    dump(out/'layout.json',summary)


def binding(out,reference):
    return dict(source_sha256=sha((reference/'training/export/rearch_fixed.c').read_bytes()),
        weights_sha256=sha((reference/'training/export/rearch_int8.bin').read_bytes()),
        exporter_sha256=sha((ROOT/'pc_ai/export_trident_network.c').read_bytes()+(ROOT/'pc_ai/export_w8a16_tasks.c').read_bytes()),
        graph_sha256=sha((out/'graph.json').read_bytes()),input_sha256=sha((out/'network0.input.bin').read_bytes()))


def golden_status(out,current):
    try:
        b=json.loads((out/'reference_binding.json').read_text());r=json.loads((out/'reference_result.json').read_text())
        if b['binding']!=current or not r['passed'] or r['golden_tensors']!=len(b['outputs']):return None
        return b,r
    except (OSError,ValueError,KeyError):return None


def sparse_segment(out,package,graph,assets,start,count,current):
    """保留全网绝对地址，只装载该区间确实读取的资产和外部依赖。"""
    checked(start>=0 and count>0 and start+count<=99,'任务区间超出0..98')
    status=golden_status(out,current)
    checked(status is not None,'需要匹配当前输入/源码/资产的C黄金结果；先运行 --golden 或 --golden-limit')
    b,r=status;end=start+count;checked(r['golden_tensors']>=end,'C黄金结果未覆盖此区间')
    selected=package.tasks[start:end];outputs=package.manifest['outputs'];initial={}
    def put(address,data):
        checked(address%16==0 and len(data)%16==0,'稀疏数据未对齐')
        for k in range(0,len(data),16):
            value=int.from_bytes(data[k:k+16],'little');a=address+k
            checked(a not in initial or initial[a]==value,'稀疏初始化区域冲突')
            initial[a]=value
    def original(address,size):return package.data[address-package.base:address-package.base+size]
    def expected_tensor(index):
        raw=(out/'golden'/f'layer{index:03d}.bin').read_bytes()
        checked(len(raw)==outputs[index]['bytes'] and sha(raw)==b['outputs'][index],'黄金结果长度/哈希不符')
        return raw
    def guards(index):
        for field in ('guard_before','guard_after'):
            address=outputs[index][field];put(address,original(address,16))
    header=package.header.copy();header[4]=count;header[5]+=start*64
    header[10]=selected[-1][4];header[11]=outputs[end-1]['bytes']
    put(package.base,words(header));put(header[5],b''.join(words(t) for t in selected))
    dependencies=set()
    for i in range(start,end):
        n=graph['nodes'][i];sources=[n['a']]+([n['b']] if n['op'] in ('add','concat') else [])
        for s in sources:
            if s<start:dependencies.add(s)
        for _,address,size in assets[i]:put(address,original(address,size))
        o=outputs[i];put(o['address'],original(o['address'],o['bytes']));guards(i)
    for s in sorted(dependencies):
        if s<0:put(package.header[8],original(package.header[8],package.header[9]))
        else:put(outputs[s]['address'],expected_tensor(s));guards(s)
    request=pack_run_request([package.base]);put(BOOT_ADDR,request[BOOT_ADDR:BOOT_ADDR+32]);put(0x2000,request[0x2000:0x2010]);put(0x4000,b'\xcc'*32)
    expected=initial.copy()
    for i in range(start,end):
        raw=expected_tensor(i);address=outputs[i]['address']
        for k in range(0,len(raw),16):expected[address+k]=int.from_bytes(raw[k:k+16],'little')
    report=words([0,0xffffffff,0,count,0,sum(task_issues(t) for t in selected)&0xffffffff,selected[-1][10],selected[-1][11]])
    for off in (0,16):expected[0x4000+off]=int.from_bytes(report[off:off+16],'little')
    directory=out/'segments'/f'{start:03d}_{count:03d}';directory.mkdir(parents=True,exist_ok=True)
    with (directory/'initial.mem').open('w') as f:
        for a,v in sorted(initial.items()):f.write(f'{(a<<128)|v:040x}\n')
    with (directory/'golden.mem').open('w') as f:
        for a,v in sorted(expected.items()):
            mask=((1<<128)-1)^(0xffffffff if a==0x4010 else 0)
            f.write(f'{(a<<256)|(mask<<128)|v:072x}\n')
    (directory/'outputs.mem').write_text(''.join(f'{(t[4]<<32)|outputs[start+i]["bytes"]:016x}\n' for i,t in enumerate(selected)))
    slots=1<<max(8,(2*len(initial)-1).bit_length())
    info=dict(start=start,count=count,input_shape=graph['input_shape'],initial=len(initial),golden=len(expected),slots=slots,
        external_dependencies=sorted(dependencies),expected_issues=sum(task_issues(t) for t in selected)&0xffffffff,
        binding=current,original_forward_compared=r['original_forward_compared'])
    dump(directory/'fixtures.json',info);return directory,info


def build_verilator(directory,slots,jobs):
    """ROM/RAM从运行目录装载，同一份编译模型可复用于不同网络区间。"""
    common=['--timing','--assert','--no-sched-zero-delay','--top-module','TB_ddr_cpu_window',
        '-O3','-CFLAGS','-O3','-Wno-TIMESCALEMOD','-y',str(ROOT/'vsrc'),'-I'+str(ROOT/'Iverilog'),
        '-DDDR3_MODEL_SLOTS='+str(slots),'-DDDR3_MODEL_STRICT_READS','-DAI_TASK_PROGRAM','-DAI_NETWORK_PROGRAM',
        '-DPROG_FILE="runner.hex"','-DDATA_FILE="runner.data"','-GCPU_TEST=1','-GAI_ENABLE=1','-GAI_ACT_WIDTH=16',
        str(ROOT/'Iverilog/TB_ddr_cpu_window.v'),str(ROOT/'vsrc/ddr3.sv')]
    version=subprocess.check_output(['verilator','--version'],text=True).strip()
    compiler=subprocess.check_output(['g++','--version'],text=True).splitlines()[0]
    sources=sorted([*(ROOT/'vsrc').glob('*.v'),*(ROOT/'vsrc').glob('*.sv'),
        ROOT/'Iverilog/TB_ddr_cpu_window.v',*(ROOT/'Iverilog').glob('*.vh')])
    signature=dict(schema=1,verilator=version,compiler=compiler,args=common,
        sources={str(p.relative_to(ROOT)):sha(p.read_bytes()) for p in sources})
    key=sha(json.dumps(signature,sort_keys=True).encode())
    cache_root=ROOT/'pc_ai/outputs/verilator_network_cache';cache=cache_root/key
    cache.mkdir(parents=True,exist_ok=True);binary=cache/'obj/network_sim';manifest=cache/'build.json'
    reused=False
    # 多个区间同时启动时，共享模型只能由一个进程编译。
    with (cache/'build.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if binary.is_file() and manifest.is_file() and json.loads(manifest.read_text())==signature:
            reused=True
        else:
            print('首次编译Verilator模型，日志：'+str(cache/'compile.log'),flush=True)
            binary.unlink(missing_ok=True)
            # 缓存和临时文件均留在工程outputs中，不依赖用户目录的写权限。
            ccache=cache_root/'ccache';(ccache/'tmp').mkdir(parents=True,exist_ok=True)
            env=dict(os.environ,CCACHE_DIR=str(ccache),CCACHE_TEMPDIR=str(ccache/'tmp'))
            run(['verilator','--binary','-j',str(jobs),'--Mdir',str(cache/'obj'),'-o','network_sim',*common],cache,'compile',env=env)
            checked(binary.is_file(),'Verilator编译未生成可执行文件');dump(manifest,signature)
    if reused:print('复用已编译的Verilator模型：'+key[:12],flush=True)
    return str(binary),dict(verilator_version=version,model_key=key,model_reused=reused,compile_log=str(cache/'compile.log'))


def build_sim(directory,info,simulator='verilator',jobs=4,model_slots=None,sim_args=()):
    started=time.perf_counter()
    lib=subprocess.check_output(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-print-libgcc-file-name'],text=True).strip()
    run(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-msmall-data-limit=0','-ffreestanding','-nostdlib','-nostartfiles',
         '-Os','-Wall','-Wextra','-Werror','-T',ROOT/'link.ld','-o','runner.elf',ROOT/'asm/start.s',
         ROOT/'csrc/software/ai_task_runner.c',ROOT/'csrc/software/ai_runtime.c',lib],directory,'firmware')
    for section,name in (('.text','runner.bin'),('.data','runner.data.bin')):
        run(['riscv64-unknown-elf-objcopy','-j',section,'-O','binary','runner.elf',name],directory,name)
    code=(directory/'runner.bin').read_bytes();data=(directory/'runner.data.bin').read_bytes()
    checked(len(code)<=32768 and len(data)<=65536,'固件超过ROM/RAM容量')
    (directory/'runner.hex').write_text(''.join(f'{int.from_bytes(code[n:n+4],"little"):08x}\n' for n in range(0,len(code),4)))
    (directory/'runner.data').write_text(''.join(f'{v:02x}\n' for v in data) or '00\n')
    backend={}
    if simulator=='verilator':
        # 按整网容量配置，后续换区间仍能命中同一编译模型；这是主机模拟内存。
        slots=max(info['slots'],model_slots or info['slots'])
        binary,backend=build_verilator(directory,slots,jobs);command=[binary]
    else:
        slots=info['slots']
        run(['iverilog','-g2012','-s','TB_ddr_cpu_window','-y',ROOT/'vsrc','-I',ROOT/'Iverilog',
             '-DDDR3_MODEL_SLOTS='+str(slots),'-DDDR3_MODEL_STRICT_READS','-DAI_TASK_PROGRAM','-DAI_NETWORK_PROGRAM',
             '-PTB_ddr_cpu_window.CPU_TEST=1','-PTB_ddr_cpu_window.AI_ENABLE=1','-PTB_ddr_cpu_window.AI_ACT_WIDTH=16',
             '-DPROG_FILE="runner.hex"','-DDATA_FILE="runner.data"',
             '-o','test.vvp',ROOT/'Iverilog/TB_ddr_cpu_window.v',ROOT/'vsrc/ddr3.sv'],directory,'compile_rtl_iverilog')
        command=['vvp','test.vvp']
    command.extend([f'+TASK_INITIAL={info["initial"]}',f'+TASK_GOLDEN={info["golden"]}',
                    f'+NETWORK_TASKS={info["count"]}',f'+NETWORK_START={info["start"]}',*sim_args])
    script='#!/usr/bin/env bash\nset -euo pipefail\ncd -- "$(dirname -- "$0")"\n'+shlex.join(command)+' "$@" | tee run_'+simulator+'.log\n'
    (directory/('run_'+simulator+'.sh')).write_text(script);(directory/'run.sh').write_text(script)
    return command,dict(rom_bytes=len(code),data_bytes=len(data),firmware_sha256=sha(code),simulator=simulator,
        simulator_slots=slots,build_wall_seconds=time.perf_counter()-started,sim_args=list(sim_args),**backend)


def check_sim_log(log,info):
    lines=re.findall(r'^PASS ai_network start=(\d+) tasks=(\d+) words=(\d+) cycles=(\d+) issues=(\d+)$',log,re.M)
    checked(len(lines)==1,'需要且只能有一条有效的ai_network PASS')
    start,count,words_count,cycles,issues=map(int,lines[0])
    checked((start,count,words_count,issues)==(info['start'],info['count'],info['golden'],info['expected_issues']),'RTL报告与区间配置不符')
    return dict(cycles=cycles,issues=issues,checked_words=words_count)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference',type=Path,default=ROOT.parent/'materials/TridentVision')
    p.add_argument('--out',type=Path,default=ROOT/'pc_ai/outputs/trident_network')
    p.add_argument('--size',type=int,default=96,help='32的倍数，默认真实96；32仅用于缩短定向测试')
    p.add_argument('--input',type=Path,help='已预处理的CHW INT16 .npy，或小端HWC INT16 .bin；缺省为诊断渐变图')
    g=p.add_mutually_exclusive_group();g.add_argument('--golden',action='store_true',help='长任务：计算99个C输出并与原forward_fixed比较')
    g.add_argument('--golden-limit',type=int,default=0,help='只计算前N个C输出，供前段定向测试')
    p.add_argument('--segment',help='准备start:count任务区间的稀疏DDR/CPU仿真；索引从0开始')
    p.add_argument('--run',action='store_true',help='长任务：执行--segment对应的CPU/RTL仿真')
    p.add_argument('--simulator',choices=('verilator','iverilog'),default='verilator',help='区间仿真后端，默认Verilator')
    p.add_argument('--jobs',type=int,default=min(4,os.cpu_count() or 1),help='Verilator首次C++编译并行数')
    p.add_argument('--sim-arg',action='append',default=[],help='传给仿真的plusarg，例如--sim-arg=+ddr3_random_stalls=1')
    args=p.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True);ref=args.reference.resolve()
    (out/'prepared.json').unlink(missing_ok=True)
    checked(not args.run or args.segment is not None,'--run须配合--segment')
    checked(args.jobs>0,'jobs必须为正数')
    checked(all(v.startswith('+') and len(v)>1 for v in args.sim_arg),'sim-arg必须是非空plusarg')
    checked(32<=args.size<=256 and args.size%32==0,'size须为32..256且为32的倍数')
    limit=99 if args.golden else args.golden_limit;checked(0<=limit<=99,'golden-limit须为0..99')
    weights=ref/'training/export/rearch_int8.bin';raw=weights.read_bytes()
    checked(len(raw)>=32 and raw[:4]==b'Y26F' and struct.unpack_from('<7I',raw,4)==(1,72,83,10,0,3,0),'参考资产头部不符')
    input_arg='-'
    if args.input:
        source=args.input.expanduser().resolve();raw_input=source.read_bytes()
        if source.suffix.lower()=='.npy':
            import numpy as np
            x=np.load(source,allow_pickle=False);checked(x.shape==(3,args.size,args.size) and x.dtype.kind=='i' and x.dtype.itemsize==2,'输入须为CHW INT16')
            raw_input=x.transpose(1,2,0).astype('<i2').tobytes()
        input_path=out/'source_input.bin';input_path.write_bytes(raw_input);input_arg=str(input_path)
    run(['gcc','-O2','-std=c11','-DTRIDENT_SOURCE='+json.dumps(str(ref/'training/export/rearch_fixed.c')),
         '-I',ref/'c_model',ROOT/'pc_ai/export_trident_network.c','-lm','-o','export_network'],out,'compile_exporter')
    (out/'golden').mkdir(exist_ok=True)
    if limit:
        # 避免C执行失败后旧的成功报告被误认为本次成功。
        (out/'reference_result.json').unlink(missing_ok=True);(out/'reference_binding.json').unlink(missing_ok=True)
    run([out/'export_network',weights,args.size,input_arg,limit,int(limit==99)],out,'export')
    graph=json.loads((out/'graph.json').read_text());spec=json.loads((out/'network0.json').read_text())
    package=pack_model(spec,0x10000,root=out,output_fill=0xa7);assets,summary=audit(package,graph)
    (out/'model.bin').write_bytes(package.data);dump(out/'model.json',package.manifest)
    (out/'request.bin').write_bytes(pack_run_request([package.base]));save_layout(out,package,graph,summary)
    run(['gcc','-O2','-std=c11','-Wall','-Wextra','-Werror',ROOT/'pc_ai/check_ai_descriptors.c','-o','check_descriptors'],out,'compile_descriptors')
    checked('PASS descriptors=99' in run([out/'check_descriptors',out/'model.bin'],out,'descriptors'),'生产固件描述符检查失败')
    current=binding(out,ref)
    if limit:
        hashes=[]
        for i in range(limit):
            raw=(out/'golden'/f'layer{i:03d}.bin').read_bytes()
            checked(len(raw)==package.manifest['outputs'][i]['bytes'],'C黄金结果物理长度不符')
            hashes.append(sha(raw))
        dump(out/'reference_binding.json',dict(binding=current,outputs=hashes))
    status=golden_status(out,current)
    result=dict(prepared=True,**summary,binding=current,golden_tensors=0 if status is None else status[1]['golden_tensors'],
        original_forward_compared=False if status is None else status[1]['original_forward_compared'],rtl_verified=False,pds_verified=False)
    if args.segment:
        fields=args.segment.split(':');checked(len(fields)==2,'segment格式为start:count')
        directory,info=sparse_segment(out,package,graph,assets,int(fields[0]),int(fields[1]),current)
        (directory/'result.json').unlink(missing_ok=True)
        (directory/('result_'+args.simulator+'.json')).unlink(missing_ok=True)
        model_words=len(package.data)//16+16
        model_slots=1<<max(8,(2*model_words-1).bit_length())
        command,firmware=build_sim(directory,info,args.simulator,args.jobs,model_slots,args.sim_arg)
        info.update(firmware);dump(directory/'fixtures.json',info);dump(directory/('fixtures_'+args.simulator+'.json'),info)
        if args.run:
            started=time.perf_counter();log=run(command,directory,'run_'+args.simulator)
            elapsed=time.perf_counter()-started;metrics=check_sim_log(log,info)
            report=dict(passed=True,**info,**metrics,simulation_wall_seconds=elapsed,full_tensor_graph=int(fields[0])==0 and int(fields[1])==99,
                full_detection_network=False,
                postprocess_in_cpu=False,pds_verified=False)
            dump(directory/'result.json',report);dump(directory/('result_'+args.simulator+'.json'),report)
            result['rtl_verified']=dict(start=info['start'],count=info['count'],input_shape=graph['input_shape'])
            print(f'{args.simulator}主机运行时间（不含编译）：{elapsed:.3f}秒',flush=True)
        print('区间仿真入口：bash '+str(directory/'run.sh'),flush=True)
    dump(out/'prepared.json',result)
    print(f'已导出99条任务、6张检测输出；模型{len(package.data)}字节，C黄金覆盖{result["golden_tensors"]}条。')
    print('本次RTL验证：'+str(result['rtl_verified'])+'；完整网络推理/仿真须显式启用。')


if __name__=='__main__':main()
