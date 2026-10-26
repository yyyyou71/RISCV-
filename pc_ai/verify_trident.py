#!/usr/bin/env python3
"""准备/运行 TridentVision 整数权重验证；完整推理由用户显式加 --run 启动。"""
import sys
sys.dont_write_bytecode=True
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import time
import numpy as np
from PIL import Image,ImageDraw,ImageOps,UnidentifiedImageError

ROOT=Path(__file__).resolve().parents[1]
NAMES=['red','orange','yellow','green','cyan','blue','pink']
RGB=[(232,44,32),(192,88,32),(176,164,16),(72,140,56),(28,188,248),(56,92,248),(200,108,168)]


def load_rgb(path):
    """由 Pillow 按内容识别格式，修正手机照片方向；多帧图只读取首帧。"""
    with Image.open(path) as image:
        image.seek(0)
        image=ImageOps.exif_transpose(image)
        if image.mode in ('RGBA','LA') or 'transparency' in image.info:
            rgba=image.convert('RGBA')
            return Image.alpha_composite(Image.new('RGBA',rgba.size,'white'),rgba).convert('RGB')
        return image.convert('RGB')


def collect_images(entries,output_dir):
    """接受文件/目录，递归收集、稳定排序、去重，记录不可解码的文件。"""
    images=[];skipped=[];seen=set();output_dir=output_dir.resolve()
    for entry in entries:
        path=entry.expanduser().resolve()
        if not path.exists():raise ValueError('输入路径不存在：'+str(entry))
        candidates=sorted(path.rglob('*'),key=lambda p:str(p).casefold()) if path.is_dir() else [path]
        for candidate in candidates:
            if not candidate.is_file():continue
            candidate=candidate.resolve()
            # 目录扫描时不把本次输出重新当输入；显式指定图片文件仍允许读取。
            if path.is_dir() and candidate.is_relative_to(output_dir):continue
            if candidate in seen:continue
            seen.add(candidate)
            try:
                image=load_rgb(candidate)
                image.close()
            except (UnidentifiedImageError,OSError,ValueError) as error:
                skipped.append(dict(path=str(candidate),reason=f'{type(error).__name__}: {error}'))
                continue
            images.append(candidate)
    return images,skipped


def first_record(path):
    data=path.read_bytes()
    if len(data)<128 or data[:4]!=b'Y26F':raise ValueError('不是 Y26F 模型')
    version,nconv,npoints,nadd,nattn,nsig,reserved=struct.unpack_from('<7I',data,4)
    if (version,nconv,npoints,nadd,nattn,nsig,reserved)!=(1,72,83,10,0,3,0):
        raise ValueError('当前桥接仅验证此份 REARCH-v1 72 卷积资产，头部与预期不同')
    offset=32
    name=data[offset:offset+48].split(b'\0')[0].decode('ascii');offset+=48
    kind,act,groups,bits=struct.unpack_from('<4B',data,offset);offset+=4
    o,c,kh,kw,sh,sw,pad=struct.unpack_from('<7I',data,offset);offset+=28
    scale,multy,shifty=struct.unpack_from('<f2i',data,offset);offset+=12
    if name!='model.0' or (kind,o,c,kh,kw,sh,sw,pad,groups,bits)!=(0,32,3,3,3,2,2,1,1,16):
        raise ValueError('第一层布局与当前参考模型不同')
    grouping=[]
    for _ in range(groups):
        grouping.append(struct.unpack_from('<2Iif',data,offset));offset+=16
    mult=np.frombuffer(data,dtype='<i4',count=groups*o,offset=offset).astype(np.int64).reshape(groups,o);offset+=groups*o*4
    bias=np.frombuffer(data,dtype='<i4',count=o,offset=offset).astype(np.int64);offset+=o*4
    weights=np.frombuffer(data,dtype=np.int8,count=o*c*kh*kw,offset=offset).reshape(o,c,kh,kw).astype(np.int64)
    audit=dict(magic='Y26F',version=version,convolutions=nconv,points=npoints,adds=nadd,
               attention=nattn,heads=nsig,file_bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),
               weights_format='INT8',activation_format='INT16',input_format='CHW INT16, pixel 0..255, scale 1/255',
               candidate_class_names=NAMES,class_mapping_source='reference training/eval_real_frame.py; matching to this binary still needs detection evidence',
               checkpoint_files=[],first_conv=dict(name=name,out_channels=o,in_channels=c,kernel=kh,stride=sh,padding=pad))
    return audit,dict(w=weights,bias=bias,mult=mult,grouping=grouping,act=act,bits=bits,multy=multy,shifty=shifty)


def round_half_up(values,shift):
    return (values+(1<<(shift-1)))>>shift if shift>0 else values<<(-shift)


def first_conv_reference(image,record):
    # 独立 NumPy 归约，对照参考模型的分组缩放、Q13 偏置和两级舍入。
    padded=np.pad(image.astype(np.int64),((0,0),(1,1),(1,1)))
    result=np.zeros((32,48,48),dtype=np.int64)
    for group,(begin,end,shift,_) in enumerate(record['grouping']):
        acc=np.zeros_like(result)
        for ky in range(3):
            for kx in range(3):
                patch=padded[begin:end,ky:ky+96:2,kx:kx+96:2]
                acc+=np.einsum('oc,chw->ohw',record['w'][:,begin:end,ky,kx],patch)
        result+=round_half_up(acc*record['mult'][group,:,None,None],shift)
    result=np.clip(result+record['bias'][:,None,None],-(1<<31),(1<<31)-1)
    if record['act']:result=np.maximum(result,0)
    return np.clip(round_half_up(result*record['multy'],record['shifty']),-32767,32767).astype('<i2')


def prepare_image(image):
    # 对应 adaptive average pooling 的整数边界；池化均值最近舍入到像素码。
    rgb=np.asarray(image.convert('RGB'),dtype=np.int64);h,w,_=rgb.shape
    integral=np.pad(rgb.cumsum(0).cumsum(1),((1,0),(1,0),(0,0)))
    y0=np.arange(96)*h//96;y1=((np.arange(96)+1)*h+95)//96
    x0=np.arange(96)*w//96;x1=((np.arange(96)+1)*w+95)//96
    total=(integral[y1[:,None],x1]-integral[y0[:,None],x1]-
           integral[y1[:,None],x0]+integral[y0[:,None],x0])
    area=(y1-y0)[:,None]*(x1-x0)[None,:]
    return np.rint(total/area[:,:,None]).astype('<i2').transpose(2,0,1).copy()


def iou(a,b):
    inter=max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
    total=max(0,a[2]-a[0])*max(0,a[3]-a[1])+max(0,b[2]-b[0])*max(0,b[3]-b[1])-inter
    return inter/total if total else 0.0


def summarize(detections,truth):
    if truth is None:return dict(labelled=False)
    used=set();tp=0
    for det in sorted(detections,key=lambda d:-d['score']):
        candidates=[(iou(det['box'],g['box']),n) for n,g in enumerate(truth)
                    if n not in used and g['class_id']==det['class_id']]
        overlap,index=max(candidates,default=(0,-1))
        if overlap>=0.5:used.add(index);tp+=1
    return dict(labelled=True,ground_truth=len(truth),true_positive=tp,false_positive=len(detections)-tp,
                false_negative=len(truth)-tp,iou_threshold=0.5,
                note='诊断合成图的统计，不是独立测试集 mAP 或实拍精度')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference',type=Path,default=ROOT.parent/'materials/TridentVision')
    parser.add_argument('--out',type=Path,default=ROOT/'pc_ai/outputs/trident_validation')
    parser.add_argument('--image',type=Path,action='append',help='图片文件或目录，可重复指定；目录递归读取，不要求 JPG 格式')
    parser.add_argument('--threshold',type=float,default=0.25)
    parser.add_argument('--run',action='store_true',help='运行完整整数网络，可能需要等待')
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    if not 0<=args.threshold<=1:parser.error('threshold 必须在 0..1 内')
    try:photos,skipped=collect_images(args.image or [],out)
    except ValueError as error:parser.error(str(error))
    (out/'skipped_images.json').write_text(json.dumps(skipped,indent=2,ensure_ascii=False)+'\n')
    if args.image and not photos:parser.error('没有找到可解码的图片，详见 '+str(out/'skipped_images.json'))
    if args.image:print(f'读取到 {len(photos)} 张照片；跳过 {len(skipped)} 个非图片/不可读取文件。',flush=True)
    ref=args.reference.resolve();weights=ref/'training/export/rearch_int8.bin'
    audit,first=first_record(weights)
    audit['checkpoint_files']=[str(p.relative_to(ref)) for p in ref.rglob('*') if p.suffix in ('.pt','.pth')]
    (out/'asset_audit.json').write_text(json.dumps(audit,indent=2,ensure_ascii=False)+'\n')
    # 样例仅用于判断现成色块权重是否有合理响应，不能用来替代真实评测。
    image=Image.new('RGB',(640,480),(30,25,20));draw=ImageDraw.Draw(image);truth=[]
    for n,color in enumerate(RGB):
        x=30+(n%4)*150;y=60+(n//4)*220;box=[x,y,x+100,y+130]
        draw.rectangle(box,fill=color);truth.append(dict(class_id=n,box=box))
    image.save(out/'seven_colors.png')
    Image.new('RGB',(640,480),(30,25,20)).save(out/'blank.png')
    cases=[('seven_colors',out/'seven_colors.png',truth),('blank',out/'blank.png',[])]+[
        (f'photo_{n:03d}_'+re.sub(r'[^\w.-]','_',p.stem)[:48],p,None) for n,p in enumerate(photos)]
    jobs=[]
    for name,path,gt in cases:
        directory=out/name;directory.mkdir(exist_ok=True)
        source=load_rgb(path);w,h=source.size
        np.save(directory/'input.npy',prepare_image(source),allow_pickle=False)
        source.close()
        scaled=None if gt is None else [dict(class_id=g['class_id'],box=[v*96/(w if i%2==0 else h) for i,v in enumerate(g['box'])]) for g in gt]
        jobs.append(dict(name=name,path=str(path),source_filename=path.name,directory=str(directory),
                         ground_truth_96=scaled,source_size=[w,h]))
    (out/'cases.json').write_text(json.dumps(jobs,indent=2,ensure_ascii=False)+'\n')
    binary=out/'trident_bridge'
    compile_result=subprocess.run(['gcc','-O2','-std=c11','-DTRIDENT_SOURCE='+json.dumps(str(ref/'training/export/rearch_fixed.c')),
        '-I',str(ref/'c_model'),str(Path(__file__).with_name('trident_infer_bridge.c')),'-lm','-o',str(binary)],capture_output=True,text=True)
    (out/'compile.log').write_text(compile_result.stdout+compile_result.stderr)
    if compile_result.returncode:raise RuntimeError('C 参考编译失败，见 '+str(out/'compile.log'))
    print(f'准备完成：{audit["convolutions"]} 卷积，{len(jobs)} 张输入；找到训练检查点数量={len(audit["checkpoint_files"])}',flush=True)
    if not args.run:
        print('尚未运行完整推理。由你执行同一命令并加 --run。');return
    print('开始完整整数推理；只在 PC 上验证已有权重，不代表 FPGA 已运行模型。',flush=True)
    results=[]
    for job in jobs:
        directory=Path(job['directory']);start=time.perf_counter()
        with (directory/'infer.log').open('w') as log:
            result=subprocess.run([str(binary),str(weights),str(directory/'input.npy'),str(directory/'raw.json'),
                str(directory/'first_conv.bin')],stdout=log,stderr=subprocess.STDOUT,cwd=directory)
        if result.returncode:raise RuntimeError('整数推理失败，见 '+str(directory/'infer.log'))
        raw=json.loads((directory/'raw.json').read_text())
        expected=first_conv_reference(np.load(directory/'input.npy'),first)
        observed=np.fromfile(directory/'first_conv.bin',dtype='<i2')
        if observed.size!=expected.size or not np.array_equal(observed.reshape(expected.shape),expected):
            raise RuntimeError('第一层独立整数对拍失败：'+job['name'])
        if raw['point_count']!=83:raise RuntimeError('前向张量数量与预期不一致')
        selected=[d for d in raw['detections'] if d['score']>=args.threshold]
        if any(not np.isfinite(d['box']).all() or not np.isfinite(d['score']) for d in selected):
            raise RuntimeError('检测输出含 NaN/Inf')
        vis=load_rgb(job['path'])
        draw=ImageDraw.Draw(vis);w,h=vis.size
        for det in selected:
            cid=det['class_id'];label=NAMES[cid] if 0<=cid<len(NAMES) else f'class_{cid}'
            box=[v*(w if i%2==0 else h)/96 for i,v in enumerate(det['box'])]
            if box[2]<=box[0] or box[3]<=box[1]:continue
            draw.rectangle(box,outline='red',width=2)
            draw.text((max(0,box[0]),max(0,box[1]-12)),f'{label} {det["score"]:.2f}',fill='white',stroke_width=1,stroke_fill='black')
        vis.save(directory/'detections.png')
        summary=dict(name=job['name'],source=job['path'],seconds=time.perf_counter()-start,first_conv_exact=True,
            above_threshold=len(selected),detections=selected,diagnostic=summarize(selected,job['ground_truth_96']),
            q13_clamps=raw['q13_clamps'],max_abs_acc=raw['max_abs_acc'])
        results.append(summary)
        print(f'{job["name"]}: first_conv=EXACT detections={len(selected)} diagnostic={summary["diagnostic"]}',flush=True)
    report=dict(pipeline_pass=True,full_network_independent_comparison=False,threshold=args.threshold,
        checkpoint_present=bool(audit['checkpoint_files']),results=results,skipped_images=skipped,
        meaning='整数前向与第一层独立对拍已执行；合成诊断图不能证明实拍精度或 COCO 检测能力')
    (out/'result.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print('流水线验证完成。请结合 detections.png 与诊断统计判断模型，不以退出码代替检测效果。')


if __name__=='__main__':main()
