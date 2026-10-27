#!/usr/bin/env python3
"""验证生产后处理与原C规则，并用小检测头完成RV32I/DDR定向仿真。"""
import sys
sys.dont_write_bytecode=True
import argparse
import json
from pathlib import Path
import random
import struct
import subprocess
import time
from postprocess_tools import (ROOT,CONFIG,REPORT,OUTPUT,MODEL,MASK,words,checked,build_tools,
    make_blocks,install_blocks,host_check,read_report,real_image,save_cpu_detections)
from prepare_trident_network import build_sim,run,check_sim_log,dump
from pack_ai_model import pack_model
from verify_w8a16_tasks import task_issues


def synthetic(directory,template,shape=(16,32),classes=17,maximum=7,threshold=0,ties=False,large=False):
    """矩形、多尺度、通道尾填充；输出物理布局与生产引擎一致。"""
    directory.mkdir(parents=True,exist_ok=True);rng=random.Random(0x2616)
    height,width=shape;strides=[8] if large else [8,16]
    metadata=dict(engine_input_shape=[height,width,3],sigmoid_y=template['sigmoid_y'],sigmoid_dy=template['sigmoid_dy'],heads=[])
    image=bytearray(0x10200);address=len(image)
    for i,stride in enumerate(strides):
        h,w=height//stride,width//stride;n=h*w;box_addr=address
        boxes=[]
        for a in range(n):boxes.extend([[-32768,-16384,-1,32767][(a+c)%4] for c in range(4)]+[32767]*12)
        raw=struct.pack('<'+'h'*len(boxes),*boxes);image.extend(raw);address+=len(raw);cls_addr=address
        logits=[]
        for a in range(n):
            logits.extend([0 if ties else rng.choice([-32768,-21845,-3,-1,0,1,3,21845,32767]) for _ in range(classes)])
            logits.extend([32767]*((-classes)%16))
        raw=struct.pack('<'+'h'*len(logits),*logits);image.extend(raw);address+=len(raw)
        metadata['heads'].append(dict(stride=stride,s_box=1/4096,multL=3,shiftL=1,
            box=dict(address=box_addr,bytes=n*32,shape=[h,w,4]),
            cls=dict(address=cls_addr,bytes=len(raw),shape=[h,w,classes])))
    header=[0x314d4941,2,64,64,1,MODEL+64,MODEL,address,MODEL+128,16,
        metadata['heads'][0]['box']['address'],metadata['heads'][0]['box']['bytes'],MODEL+256,1,0,0]
    image[MODEL:MODEL+64]=words(header)
    image[0x1000:0x1020]=words([0x31524941,1,1,0x2000,0x4000,0,0,0])
    image[0x2000:0x2010]=words([MODEL,0,0,0]);image[0x4000:0x4020]=b'\xcc'*32
    path=directory/'ddr_image.bin';path.write_bytes(image)
    blocks=make_blocks(metadata,maximum,threshold);install_blocks(path,blocks)
    dump(directory/'heads.json',metadata);return path,blocks


def cpu_fixture(directory,image,report,records,summary):
    # 主机运行已经写出结果；先恢复毒值，避免CPU测试预装正确输出。
    raw=bytearray(image.read_bytes());output_bytes=len(records)
    cfg=struct.unpack_from('<16I',raw,CONFIG)
    raw[OUTPUT:OUTPUT+cfg[9]]=b'\xa5'*cfg[9];raw[REPORT:REPORT+32]=b'\xcc'*32
    expected=raw.copy();expected[0x4000:0x4020]=words([0,0xffffffff,0,0,0,0,0,0])
    expected[REPORT:REPORT+32]=report;expected[OUTPUT:OUTPUT+output_bytes]=records
    checked(len(raw)%16==0,'CPU夹具长度未对齐')
    with (directory/'initial.mem').open('w') as f:
        for a in range(0,len(raw),16):f.write(f'{(a<<128)|int.from_bytes(raw[a:a+16],"little"):040x}\n')
    with (directory/'golden.mem').open('w') as f:
        for a in range(0,len(expected),16):
            f.write(f'{(a<<256)|(MASK<<128)|int.from_bytes(expected[a:a+16],"little"):072x}\n')
    (directory/'outputs.mem').write_text('')
    return dict(start=0,count=0,input_shape=list(cfg[12:14])+[3],initial=len(raw)//16,golden=len(raw)//16,
        slots=1<<max(8,(len(raw)//8-1).bit_length()),external_dependencies=[],expected_issues=0,
        postprocess=dict(summary,output_address=OUTPUT,output_bytes=output_bytes,report_code=struct.unpack_from('<I',report)[0]))


def run_cpu(directory,info,simulator='verilator',extra=()):
    arguments=['+POST_ENABLE=1','+POST_ONLY=1',f'+POST_OUTPUT_ADDR={OUTPUT}',
        f'+POST_OUTPUT_BYTES={info["postprocess"]["output_bytes"]}',*extra]
    command,firmware=build_sim(directory,info,simulator,sim_args=arguments,firmware_kind='post_only')
    info={**info,**firmware};dump(directory/('fixtures_'+simulator+'.json'),info)
    started=time.perf_counter();log=run(command,directory,'run_'+simulator)
    save_cpu_detections(directory,info)
    result=dict(passed=True,**info,**check_sim_log(log,info),simulation_wall_seconds=time.perf_counter()-started,
        full_tensor_graph=False,full_detection_network=False,postprocess_in_cpu=True,pds_verified=False)
    dump(directory/('result_'+simulator+'.json'),result);return result


def combined_check(directory,template,tools):
    """真实调度固件先跑一个卷积生成分类头，再进入后处理；无需长整网仿真。"""
    directory.mkdir(exist_ok=True);height,width,classes=2,3,17
    logits=list(range(-8,9));padded=32
    spec=dict(activation_bits=16,input=dict(shape=[height,width,1],data=[0]*(height*width)),layers=[dict(
        name='cls',op='conv2d',input='input',out_channels=classes,kernel=1,stride=1,padding=0,
        bias_enable=True,biases=[v*8192 for v in logits],weights=[0]*classes,relu=False,
        quant_q13=[[8192,0,0,0,1,13] for _ in logits])])
    package=pack_model(spec,MODEL,root=directory,output_fill=0xa7)
    tensor=package.manifest['outputs'][0];box_addr=package.header[7]
    boxes=struct.pack('<'+'h'*(height*width*16),*([4096]*4+[0]*12)*(height*width))
    package.header[7]+=len(boxes)
    image_data=bytearray(MODEL)+bytearray(package.data)+bytearray(boxes)
    image_data[MODEL:MODEL+64]=words(package.header)
    image_data[0x1000:0x1020]=words([0x31524941,1,1,0x2000,0x4000,0,0,0])
    image_data[0x2000:0x2010]=words([MODEL,0,0,0]);image_data[0x4000:0x4020]=b'\xcc'*32
    cls_raw=struct.pack('<'+'h'*(height*width*padded),*((logits+[0]*(padded-classes))*(height*width)))
    image_data[tensor['address']:tensor['address']+tensor['bytes']]=cls_raw
    metadata=dict(engine_input_shape=[height*8,width*8,3],sigmoid_y=template['sigmoid_y'],sigmoid_dy=template['sigmoid_dy'],
        heads=[dict(stride=8,s_box=1/4096,multL=3,shiftL=1,box=dict(address=box_addr,bytes=len(boxes),shape=[height,width,4]),
            cls=dict(address=tensor['address'],bytes=tensor['bytes'],shape=[height,width,classes]))])
    image=directory/'ddr_image.bin';image.write_bytes(image_data);blocks=make_blocks(metadata,7,0);install_blocks(image,blocks)
    report,records,summary=host_check(directory,image,tools)
    info=cpu_fixture(directory,image,report,records,summary)
    info.update(count=1,expected_issues=task_issues(package.tasks[0]))
    initial_rows=(directory/'initial.mem').read_text().splitlines();golden_rows=(directory/'golden.mem').read_text().splitlines()
    for offset in range(0,tensor['bytes'],16):
        a=tensor['address']+offset;initial_rows[a//16]=f'{(a<<128)|int.from_bytes(bytes([0xa7])*16,"little"):040x}'
    final_report=words([0,0xffffffff,0,1,0,info['expected_issues'],height,width])
    for offset in (0,16):
        a=0x4000+offset;mask=MASK^(0xffffffff if offset else 0)
        golden_rows[a//16]=f'{(a<<256)|(mask<<128)|int.from_bytes(final_report[offset:offset+16],"little"):072x}'
    (directory/'initial.mem').write_text('\n'.join(initial_rows)+'\n');(directory/'golden.mem').write_text('\n'.join(golden_rows)+'\n')
    (directory/'outputs.mem').write_text(f'{(tensor["address"]<<32)|tensor["bytes"]:016x}\n')
    arguments=['+POST_ENABLE=1',f'+POST_OUTPUT_ADDR={OUTPUT}',f'+POST_OUTPUT_BYTES={len(records)}']
    command,firmware=build_sim(directory,info,sim_args=arguments,firmware_kind='detection')
    info.update(firmware);dump(directory/'fixtures_verilator.json',info)
    started=time.perf_counter();log=run(command,directory,'run_verilator')
    save_cpu_detections(directory,info)
    result=dict(passed=True,**info,**check_sim_log(log,info),simulation_wall_seconds=time.perf_counter()-started,
        full_tensor_graph=False,full_detection_network=False,postprocess_in_cpu=True,pds_verified=False)
    dump(directory/'result_verilator.json',result);return result


def negative_checks(directory,image,blocks,tools):
    original=image.read_bytes();results={}
    cases=[('magic',CONFIG,0,1),('too_many_results',CONFIG+7*4,301,1),
        ('metadata_overlap',CONFIG+5*4,CONFIG,2),('model_mismatch',CONFIG+10*4,MODEL+16,2),
        ('invalid_shift',0x5100+7*4,64,4),('readonly_tensor',0x5100,MODEL,2),
        ('last_head_reserved',0x5140+10*4,1,4),('nonmonotone_lut',0x5200+4,0,4),
        ('coordinate_overflow',0x5100+8*4,0x7fffffff,4)]
    for name,address,value,expected in cases:
        modified=bytearray(original);struct.pack_into('<I',modified,address,value)
        # 坐标溢出测试同时去掉缩放，才会超出有符号Q16范围。
        if name=='coordinate_overflow':struct.pack_into('<I',modified,0x5100+9*4,0)
        image.write_bytes(modified);install_blocks(image,{OUTPUT:blocks[OUTPUT]})
        report_path=directory/(name+'.bin')
        subprocess.run([str(tools/'post_host'),str(image),str(CONFIG),str(MODEL),str(report_path)],check=True)
        r=read_report(report_path);checked(r[0]==expected and r[1]==0,name+'未按预期拒绝')
        checked(image.read_bytes()[OUTPUT:OUTPUT+len(blocks[OUTPUT])]==blocks[OUTPUT],name+'错误时写了结果')
        results[name]=True
    for name,read_at,write_at,count in [('read_error',1,0,0),('late_read_error',7,0,0),('write_error',0,2,1)]:
        image.write_bytes(original);install_blocks(image,{OUTPUT:blocks[OUTPUT]})
        report_path=directory/(name+'.bin')
        subprocess.run([str(tools/'post_host'),str(image),str(CONFIG),str(MODEL),str(report_path),str(read_at),str(write_at)],check=True)
        r=read_report(report_path);checked(r[0]==5 and r[1]==r[6]==count,name+'错误或部分写回计数不正确')
        checked(image.read_bytes()[OUTPUT+count*32:OUTPUT+len(blocks[OUTPUT])]==blocks[OUTPUT][count*32:],name+'覆盖了未完成记录')
        results[name]=True
    image.write_bytes(original);return results


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--network',type=Path,default=ROOT/'pc_ai/outputs/trident_network')
    parser.add_argument('--out',type=Path,default=ROOT/'pc_ai/outputs/ai_postprocess')
    parser.add_argument('--reference',type=Path,default=ROOT.parent/'materials/TridentVision')
    parser.add_argument('--host-only',action='store_true',help='只运行主机数值/异常检查')
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    tools=build_tools(out,args.reference.resolve());network=args.network.resolve()
    metadata=json.loads((network/'heads.json').read_text());summary={}
    for name,maximum,threshold in [('real_default',300,16384),('real_all',300,0),('real_empty',300,65535),('real_top7',7,0)]:
        directory=out/name;directory.mkdir(exist_ok=True);blocks=make_blocks(metadata,maximum,threshold)
        image=real_image(network,directory,blocks)
        original=json.loads((network/'detections.json').read_text()) if maximum==300 else None
        _,_,summary[name]=host_check(directory,image,tools,original)
    cases=[('rectangular',{}),('ties',dict(ties=True,maximum=3)),
        ('prune_anchors',dict(shape=(160,160),large=True,maximum=300)),
        ('max_classes',dict(classes=128,maximum=5))]
    for name,options in cases:
        directory=out/name;image,blocks=synthetic(directory,metadata,**options)
        report,records,summary[name]=host_check(directory,image,tools)
        if name=='rectangular':
            summary['negative_checks']=negative_checks(directory,image,blocks,tools)
            if not args.host_only:
                info=cpu_fixture(directory,image,report,records,summary[name])
                summary['cpu_verilator']=run_cpu(directory,info)
                summary['cpu_iverilog']=run_cpu(directory,info,'iverilog')
                stalled=out/'rectangular_stalls';stalled.mkdir(exist_ok=True)
                for filename in ('initial.mem','golden.mem','outputs.mem'):(stalled/filename).write_bytes((directory/filename).read_bytes())
                summary['cpu_stalls']=run_cpu(stalled,info,extra=('+cpu_half_ns=7','+ddr3_core_period_ns=6','+ddr3_random_stalls=1'))
                # 最后一个头格式错误：真实CPU也必须拒绝，且不写任何检测记录。
                invalid=out/'invalid_last_head';invalid.mkdir(exist_ok=True)
                bad_image,bad_blocks=synthetic(invalid,metadata)
                with bad_image.open('r+b') as f:f.seek(0x5140+40);f.write(words([1]))
                subprocess.run([str(tools/'post_host'),str(bad_image),str(CONFIG),str(MODEL),str(invalid/'host_report.bin')],check=True)
                bad_report=(invalid/'host_report.bin').read_bytes();checked(struct.unpack_from('<I',bad_report)[0]==4,'负向CPU夹具错误')
                bad_info=cpu_fixture(invalid,bad_image,bad_report,b'',dict(passed=True,count=0))
                summary['cpu_reject']=run_cpu(invalid,bad_info)
    if not args.host_only:summary['cpu_combined']=combined_check(out/'combined',metadata,tools)
    dump(out/'verification.json',dict(passed=True,**summary))
    print('PASS ai_postprocess: original-C rules, stable Top-K, bounds, faults'+('' if args.host_only else ', RV32I/DDR both simulators'))


if __name__=='__main__':main()
