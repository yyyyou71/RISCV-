#!/usr/bin/env python3
"""把已有整数卷积网络打包成 AIM1 数据包；不训练、不校准，也不读取 ONNX。"""
import sys
sys.dont_write_bytecode = True
import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import struct
from conv2d_reference import ConvConfig, conv2d
from quant_reference import pack_hwc_int8, pack_quant_params, quantize_hwc

VERSION=1
VERSION_W8A16=2
MODEL_MAGIC=int.from_bytes(b'AIM1','little')
RUN_MAGIC=int.from_bytes(b'AIR1','little')
BOOT_ADDR=0x1000
MODEL_MIN=0x10000
DDR_BYTES=0x20000000
OP_CONV2D=1
OP_ADD=2
OP_CONCAT=3
OP_MAXPOOL5=4


def align(value,boundary=16):
    return (value+boundary-1)//boundary*boundary


def words(values):
    return struct.pack('<'+'I'*len(values),*values)


def pack_run_request(model_addresses):
    """前 64 KiB 调度区镜像：AIR1@0x1000、模型列表@0x2000、报告@0x4000。"""
    if not 1<=len(model_addresses)<=64 or any(type(a) is not int or a%16 or not MODEL_MIN<=a<=DDR_BYTES-64 for a in model_addresses):
        raise ValueError('请求必须包含 1..64 个合法模型头地址')
    image=bytearray(MODEL_MIN)
    image[BOOT_ADDR:BOOT_ADDR+32]=words([RUN_MAGIC,VERSION,len(model_addresses),0x2000,0x4000,0,0,0])
    for n,address in enumerate(model_addresses):image[0x2000+n*16:0x2010+n*16]=words([address,0,0,0])
    return bytes(image)


def array(item,key,file_key,count,width,root):
    if (key in item)==(file_key in item):
        raise ValueError(f'{key} 与 {file_key} 必须且只能提供一个')
    if file_key in item:
        raw=(root/item[file_key]).read_bytes()
        if len(raw)!=count*(width//8):raise ValueError(f'{file_key} 长度错误')
        values=list(struct.unpack('<'+{8:'b',16:'h',32:'i'}[width]*count,raw))
    else:
        values=item[key]
    if not isinstance(values,list) or len(values)!=count or any(type(v) is not int or not -(1<<(width-1))<=v<(1<<(width-1)) for v in values):
        raise ValueError(f'{key} 长度或 INT{width} 范围错误')
    return values


@dataclass
class ModelPackage:
    base: int
    data: bytes
    header: list
    tasks: list
    manifest: dict
    golden: dict


def pack_hwc_int16(values,channels):
    """只补齐/重排，不计算卷积；低字节在前，每像素补齐到16通道。"""
    result=bytearray()
    for p in range(len(values)//channels):
        result.extend(struct.pack('<'+'h'*channels,*values[p*channels:(p+1)*channels]))
        result.extend(bytes((align(channels)-channels)*2))
    return bytes(result)


def pack_q13_params(params):
    records=bytearray()
    for q in params:
        if not isinstance(q,(list,tuple)) or len(q)!=6 or any(type(v) is not int for v in q):
            raise ValueError('quant_q13 每通道必须为6个整数 [M0,S0,M1,S1,MY,SY]')
        if any(not 0<=q[i]<(1<<31) for i in (0,2,4)) or any(not 0<=q[i]<=95 for i in (1,3,5)):
            raise ValueError('Q13乘数必须为非负31位整数，右移必须为0..95')
        records.extend(words([*q,0,0]))
    records.extend(bytes((align(len(params),4)-len(params))*32))
    return bytes(records)


def pack_add_params(params):
    if not isinstance(params,(list,tuple)) or len(params)!=4 or any(type(v) is not int for v in params):
        raise ValueError('quant_add必须为[MA,SA,MB,SB]四个整数')
    if any(not 0<=params[i]<(1<<31) for i in (0,2)) or any(not 0<=params[i]<=63 for i in (1,3)):
        raise ValueError('ADD乘数须为非负31位整数，右移须为0..63')
    return words(params)


def pack_model(spec,base=MODEL_MIN,root=Path('.'),reference=False,output_fill=0):
    if base<MODEL_MIN or base%16 or base>=DDR_BYTES:raise ValueError('模型基地址必须在 64 KiB..512 MiB 内且按 16 字节对齐')
    bits=spec.get('activation_bits',8)
    if type(bits) is not int or bits not in (8,16):raise ValueError('activation_bits仅支持8或16')
    wide=bits==16
    if wide and reference:raise ValueError('W8A16期望值使用参考C模型生成；不提供独立Python整网数学参考')
    image=spec['input'];shape=tuple(image['shape'])
    if len(shape)!=3 or any(type(v) is not int or not 1<=v<=65535 for v in shape):raise ValueError('输入 shape 必须为 H,W,C，范围 1..65535')
    layers=spec['layers']
    if not isinstance(layers,list) or not layers:raise ValueError('网络至少需要一个算子')
    source_values=array(image,'data','data_file',shape[0]*shape[1]*shape[2],bits,root)
    blob=bytearray(64+64*len(layers))
    def allocate(data):
        address=base+len(blob)
        blob.extend(data);blob.extend(bytes(align(len(blob))-len(blob)))
        if base+len(blob)>DDR_BYTES:raise ValueError('模型包超出 DDR 容量')
        return address
    image_bytes=(pack_hwc_int16 if wide else pack_hwc_int8)(source_values,shape[2])
    image_addr=allocate(image_bytes)
    tensors={'input':dict(shape=shape,address=image_addr,int8=not wide,bits=bits)}
    prepared=[]
    for index,layer in enumerate(layers):
        name=layer.get('name',f'layer{index}')
        source=layer.get('input','input' if index==0 else prepared[-1]['name'])
        if not isinstance(name,str) or name in tensors:raise ValueError('层名称必须唯一')
        if source not in tensors:raise ValueError('输入必须是已存在的张量，任务需按拓扑顺序给出')
        previous=tensors[source]
        if previous['bits']!=bits:raise ValueError('前层输出位宽不能作为当前卷积输入')
        if layer.get('op')=='maxpool5':
            if not wide:raise ValueError('MaxPool5当前仅支持W8A16版本2')
            if set(layer)-{'name','op','input'}:raise ValueError('MaxPool5固定K5/S1/P2，不接受量化或卷积配置')
            ih,iw,ci=previous['shape']
            prepared.append(dict(name=name,source=source,op='maxpool5',
                cfg=ConvConfig(ih,iw,ci,ci,1,1,0,False),wa=0,ba=0,qa=0,int8=False,relu=False,split=0))
            tensors[name]=dict(shape=previous['shape'],int8=False,bits=16)
            continue
        if layer.get('op')=='concat':
            if not wide:raise ValueError('Concat当前仅支持W8A16版本2')
            if set(layer)-{'name','op','input','input_b'}:raise ValueError('Concat只搬运数据，不接受量化或卷积配置')
            source_b=layer.get('input_b')
            if not isinstance(source_b,str) or source_b not in tensors or tensors[source_b]['bits']!=16 or tensors[source_b]['shape'][:2]!=previous['shape'][:2]:
                raise ValueError('Concat两路输入必须已存在、均为INT16且高宽相同')
            ih,iw,ca=previous['shape'];cb=tensors[source_b]['shape'][2];co=ca+cb
            if co>65535:raise ValueError('Concat输出通道数不能超过65535')
            prepared.append(dict(name=name,source=source,source_b=source_b,op='concat',
                cfg=ConvConfig(ih,iw,ca,co,1,1,0,False),wa=0,ba=0,qa=0,int8=False,relu=False,split=cb))
            tensors[name]=dict(shape=(ih,iw,co),int8=False,bits=16)
            continue
        if layer.get('op')=='add':
            if not wide:raise ValueError('ADD当前仅支持W8A16版本2')
            if set(layer)-{'name','op','input','input_b','quant_add'}:raise ValueError('ADD不接受卷积或ReLU配置')
            source_b=layer.get('input_b')
            if not isinstance(source_b,str) or source_b not in tensors or tensors[source_b]['shape']!=previous['shape'] or tensors[source_b]['bits']!=16:
                raise ValueError('ADD第二输入必须已存在且形状、位宽与第一输入相同')
            ih,iw,ci=previous['shape'];params=layer.get('quant_add')
            qa=allocate(pack_add_params(params))
            prepared.append(dict(name=name,source=source,source_b=source_b,op='add',
                cfg=ConvConfig(ih,iw,ci,ci,1,1,0,False),wa=0,ba=0,qa=qa,int8=False,relu=False,split=0))
            tensors[name]=dict(shape=previous['shape'],int8=False,bits=16)
            continue
        if layer.get('op','conv2d')!='conv2d':raise ValueError('未知算子；支持conv2d/add/concat/maxpool5')
        ih,iw,ci=previous['shape'];co=layer['out_channels']
        for field,default in [('out_channels',co),('kernel',3),('stride',1),('padding',1)]:
            if type(layer.get(field,default)) is not int:raise ValueError(f'{field} 必须为整数')
        for field,default in [('bias_enable',True),('output_int8',True),('relu',False)]:
            if type(layer.get(field,default)) is not bool:raise ValueError(f'{field} 必须为布尔值')
        cfg=ConvConfig(ih,iw,ci,co,layer.get('kernel',3),layer.get('stride',1),layer.get('padding',1),layer.get('bias_enable',True))
        oh,ow,_=cfg.output_shape()
        weights=array(layer,'weights','weights_file',co*cfg.kernel**2*ci,8,root)
        biases=array(layer,'biases','biases_file',co,32,root) if cfg.bias_enable else [0]*co
        if wide and ('output_int8' in layer or 'quant' in layer):raise ValueError('W8A16固定输出INT16，使用quant_q13配置量化')
        if not wide and ('quant_q13' in layer or layer.get('group_split',0)!=0):raise ValueError('W8A8不支持Q13参数或多尺度分组')
        split=layer.get('group_split',0)
        if type(split) is not int or split<0 or (split and (split%16 or split>=ci)):
            raise ValueError('group_split必须为0或小于Cin的16对齐通道数')
        int8=not wide and layer.get('output_int8',True);relu=layer.get('relu',False)
        if not wide and not int8 and relu:raise ValueError('原始 INT64 输出不能开启 ReLU')
        params=layer.get('quant_q13' if wide else 'quant',[])
        if wide and (not isinstance(params,list) or len(params)!=co):raise ValueError('每个输出通道必须提供quant_q13参数')
        if int8 and len(params)!=co:raise ValueError('每个输出通道必须提供 [multiplier,shift]')
        if int8 and any(not isinstance(q,(list,tuple)) or len(q)!=2 or any(type(v) is not int for v in q) for q in params):
            raise ValueError('quant 必须为整数 [multiplier,shift] 列表')
        cip=align(ci);cop=align(co,4)
        wb=bytearray()
        for o in range(cop):
            for tap in range(cfg.kernel**2):
                wb.extend((weights[(o*cfg.kernel**2+tap)*ci+c]&255) if o<co and c<ci else 0 for c in range(cip))
        wa=allocate(wb)
        ba=allocate(b''.join(struct.pack('<i',biases[c] if c<co else 0) for c in range(cop))) if cfg.bias_enable else 0
        qa=allocate(pack_q13_params(params)) if wide else allocate(pack_quant_params(params)) if int8 else 0
        item=dict(name=name,source=source,cfg=cfg,weights=weights,biases=biases,params=params,
                  wa=wa,ba=ba,qa=qa,int8=int8,relu=relu,split=split)
        prepared.append(item)
        tensors[name]=dict(shape=(oh,ow,co),int8=int8,bits=16 if wide else 8 if int8 else 64)
    readonly_end=base+len(blob)
    golden={};dense={'input':source_values};tasks=[];outputs=[]
    for item in prepared:
        cfg=item['cfg'];name=item['name'];oh,ow,co=tensors[name]['shape']
        size=oh*ow*(align(co)*2 if wide else align(co) if item['int8'] else align(co,4)*8)
        guard_before=allocate(bytes([0xa5])*16)
        out=allocate(bytes([output_fill])*size)
        guard_after=allocate(bytes([0x5a])*16)
        tensors[name]['address']=out
        control=cfg.kernel|(cfg.stride<<2)|(cfg.padding<<4)|(int(cfg.bias_enable)<<6)
        post=(4 if wide else int(item['int8']))|(int(item['relu'])<<1)
        is_binary=item.get('op') in ('add','concat')
        opcode={'add':OP_ADD,'concat':OP_CONCAT,'maxpool5':OP_MAXPOOL5}.get(item.get('op'),OP_CONV2D)
        task=[opcode,tensors[item['source']]['address'],
              tensors[item['source_b']]['address'] if is_binary else item['wa'],item['ba'],out,item['qa'],
              cfg.height|(cfg.width<<16),cfg.in_channels|(co<<16),control if opcode==OP_CONV2D else 0,post,oh,ow,item['split'],0,0,0]
        tasks.append(task)
        output=dict(name=name,address=out,bytes=size,shape=[oh,ow,co],int8=item['int8'],
                    guard_before=guard_before,guard_after=guard_after,element_bits=tensors[name]['bits'],op=item.get('op','conv2d'))
        outputs.append(output)
        if reference:
            values=conv2d(cfg,dense[item['source']],item['weights'],item['biases'])
            if item['int8']:
                values=quantize_hwc(values,co,item['params'],item['relu'])
                data=pack_hwc_int8(values,co)
            else:
                data=b''.join(struct.pack('<q',values[p*co+c] if c<co else 0)
                              for p in range(oh*ow) for c in range(align(co,4)))
            dense[name]=values;golden[out]=data
    final=outputs[-1]
    version=VERSION_W8A16 if wide else VERSION
    header=[MODEL_MAGIC,version,64,64,len(tasks),base+64,base,base+len(blob),
            image_addr,len(image_bytes),final['address'],final['bytes'],readonly_end,int(wide),0,0]
    blob[:64]=words(header)
    for n,task in enumerate(tasks):blob[64+n*64:128+n*64]=words(task)
    manifest=dict(abi=version,activation_bits=bits,base=base,bytes=len(blob),task_count=len(tasks),tasks_addr=base+64,
                  readonly_end=readonly_end,input=dict(address=image_addr,bytes=len(image_bytes),shape=list(shape)),
                  outputs=outputs,final_output=final)
    return ModelPackage(base,bytes(blob),header,tasks,manifest,golden)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('spec',type=Path,help='整数网络 JSON；相对数据文件路径相对该 JSON')
    parser.add_argument('--base',type=lambda v:int(v,0),default=MODEL_MIN)
    parser.add_argument('--output',type=Path,required=True,help='模型二进制包')
    parser.add_argument('--reference',action='store_true',help='同时用 Python 整数参考计算各层输出')
    parser.add_argument('--request',type=Path,help='同时生成单模型的 64 KiB 调度区镜像，装入 DDR 地址 0')
    args=parser.parse_args()
    try:
        package=pack_model(json.loads(args.spec.read_text()),args.base,args.spec.parent,args.reference)
    except (ValueError,KeyError,TypeError,OSError) as error:
        parser.error(str(error))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes(package.data)
    args.output.with_suffix('.json').write_text(json.dumps(package.manifest,indent=2,ensure_ascii=False)+'\n')
    if args.request:
        args.request.parent.mkdir(parents=True,exist_ok=True)
        args.request.write_bytes(pack_run_request([package.base]))
    for address,data in package.golden.items():
        args.output.with_name(args.output.stem+f'.golden_{address:08x}.bin').write_bytes(data)
    print(f'AIM1: tasks={len(package.tasks)} bytes={len(package.data)} base=0x{package.base:08x}')


if __name__=='__main__':main()
