"""AIP1打包、主机参考检查与CPU仿真数据准备；不执行网络前向。"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT=Path(__file__).resolve().parents[1]
CONFIG=0x5000
REPORT=0x5040
HEADS=0x5100
LUT=0x5200
OUTPUT=0x8000
MODEL=0x10000
MASK=(1<<128)-1


def checked(condition,message):
    if not condition:raise ValueError(message)


def words(values):return struct.pack('<'+'I'*len(values),*values)


def build_tools(out,reference):
    directory=out/'postprocess_tools';directory.mkdir(parents=True,exist_ok=True)
    common=['gcc','-O2','-std=c11','-Wall','-Wextra','-Werror']
    commands={
        'post_host':[*common,ROOT/'pc_ai/postprocess_host.c',ROOT/'csrc/software/ai_postprocess.c','-o',directory/'post_host'],
        'post_reference':['gcc','-O2','-std=c11','-DTRIDENT_SOURCE='+json.dumps(str(reference/'training/export/rearch_fixed.c')),
            '-I',reference/'c_model',ROOT/'pc_ai/postprocess_reference.c','-lm','-o',directory/'post_reference']}
    for name,command in commands.items():
        result=subprocess.run(list(map(str,command)),capture_output=True,text=True)
        (directory/(name+'.log')).write_text(result.stdout+result.stderr)
        checked(result.returncode==0,'后处理工具编译失败：'+str(directory/(name+'.log')))
    return directory


def make_blocks(metadata,max_detections=300,threshold=16384):
    checked(1<=max_detections<=300 and 0<=threshold<=65535,'Top-K/阈值越界')
    heads=metadata['heads'];checked(1<=len(heads)<=4,'检测头数量越界')
    raw=[]
    for h in heads:
        bh,bw,bc=h['box']['shape'];ch,cw,classes=h['cls']['shape']
        checked((bh,bw,bc)==(ch,cw,4),'检测头形状不匹配')
        # 原资产s_box是float32；先恢复该精度，再精确表示其像素Q16系数。
        scale=struct.unpack('<f',struct.pack('<f',h['s_box']))[0]
        multiplier,divisor=(scale*h['stride']*65536).as_integer_ratio()
        shift=divisor.bit_length()-1
        checked(divisor==1<<shift and 0<multiplier<=0x7fffffff and shift<=63,'框定点系数不可表示')
        raw.extend([h['box']['address'],h['cls']['address'],bh,bw,classes,h['stride'],h['multL'],h['shiftL'],multiplier,shift,*([0]*6)])
    height,width,_=metadata['engine_input_shape']
    header=[0x31504941,1,64,64,len(heads),HEADS,threshold,max_detections,
        OUTPUT,max_detections*32,MODEL,LUT,height,width,0,0]
    blocks={CONFIG:words(header),REPORT:b'\xcc'*32,HEADS:words(raw),
        LUT:words(metadata['sigmoid_y']+metadata['sigmoid_dy']),OUTPUT:b'\xa5'*(max_detections*32),
        OUTPUT-16:b'\x69'*16,OUTPUT+max_detections*32:b'\x96'*16,REPORT+32:b'\x3c'*16}
    # 最大300条结果加尾哨兵仍在前64KiB保留区。
    checked(OUTPUT+max_detections*32+16<=MODEL,'后处理输出超过保留区')
    return blocks


def install_blocks(path,blocks):
    with path.open('r+b') as f:
        for address,data in blocks.items():f.seek(address);f.write(data)


def read_report(path):return list(struct.unpack('<8I',path.read_bytes()))


def read_detections(image,count):
    with image.open('rb') as f:f.seek(OUTPUT);raw=f.read(count*32)
    checked(len(raw)==count*32,'检测输出长度错误')
    rows=[]
    for values in struct.iter_unpack('<4i4I',raw):
        checked(values[7]==0,'检测输出保留字段非零')
        rows.append(dict(box=[v/65536 for v in values[:4]],score_q16=values[4],class_id=values[5],anchor_id=values[6]))
    return raw,rows


def save_cpu_detections(directory,info):
    """读取测试台从真实DDR输出区导出的字，区别于主机生成的期望值。"""
    count=info['postprocess']['count'];lines=(directory/'cpu_detections.mem').read_text().splitlines()
    checked(len(lines)==count*2,'CPU检测输出转储长度错误')
    raw=b''.join(int(line,16).to_bytes(16,'little') for line in lines)
    rows=[]
    for values in struct.iter_unpack('<4i4I',raw):
        checked(values[7]==0,'CPU检测保留字段非零')
        rows.append(dict(box=[v/65536 for v in values[:4]],score=values[4]/65536,
            score_q16=values[4],class_id=values[5],anchor_id=values[6]))
    (directory/'cpu_detections.bin').write_bytes(raw)
    (directory/'cpu_detections.json').write_text(json.dumps(dict(report_code=info['postprocess']['report_code'],
        coordinate_space='model input pixels, unclipped',detections=rows),indent=2)+'\n')


def host_check(directory,image,tools,original=None):
    report_path=directory/'host_report.bin'
    subprocess.run([str(tools/'post_host'),str(image),str(CONFIG),str(MODEL),str(report_path)],check=True)
    report=read_report(report_path);checked(report[0]==0,'生产后处理主机运行失败：'+str(report))
    subprocess.run([str(tools/'post_reference'),str(image),str(CONFIG),str(directory/'reference.json')],check=True)
    reference=json.loads((directory/'reference.json').read_text());raw,actual=read_detections(image,report[1])
    checked(len(actual)==len(reference),'两次Top-K结果数量不一致')
    worst=0.0
    for a,b in zip(actual,reference):
        checked(all(a[k]==b[k] for k in ('score_q16','class_id','anchor_id')),'置信度/稳定排序不一致')
        error=max(abs(x-y) for x,y in zip(a['box'],b['box']));worst=max(worst,error)
        checked(error<=1/256,'定点框与原浮点公式误差超过1/256像素')
    if original is not None:
        # 已保存的原始forward_fixed输出是额外独立锚点；无需重跑卷积。
        with image.open('rb') as f:f.seek(CONFIG);cfg=struct.unpack('<16I',f.read(64))
        selected=[v for v in original if round(v['score']*65536)>=cfg[6]]
        checked(len(actual)==len(selected),'与原forward_fixed的检测数量不一致')
        for a,b in zip(actual,selected):
            checked(a['class_id']==b['class_id'] and a['score_q16']==round(b['score']*65536),'与原forward_fixed排序/分数不一致')
            checked(max(abs(x-y) for x,y in zip(a['box'],b['box']))<=1/256,'与原forward_fixed框坐标不一致')
    summary=dict(passed=True,count=report[1],anchors=report[2],selected_anchors=report[3],
        max_coordinate_error_pixels=worst,score_and_stable_order_exact=True,original_forward_compared=original is not None)
    (directory/'host_result.json').write_text(json.dumps(summary,indent=2)+'\n')
    (directory/'detections.json').write_text(json.dumps(actual,indent=2)+'\n')
    return bytes(report_path.read_bytes()),raw,summary


def real_image(out,directory,blocks):
    metadata=json.loads((out/'heads.json').read_text());manifest=json.loads((out/'model.json').read_text())
    binding=json.loads((out/'reference_binding.json').read_text())
    image=directory/'ddr_image.bin'
    with image.open('wb') as f:f.write(bytes(MODEL));f.write((out/'model.bin').read_bytes())
    with image.open('r+b') as f:
        for h in metadata['heads']:
            for field in ('box','cls'):
                tensor=h[field];raw=(out/'golden'/f'layer{tensor["node"]:03d}.bin').read_bytes()
                checked(hashlib.sha256(raw).hexdigest()==binding['outputs'][tensor['node']],'检测头黄金值哈希不符')
                checked(len(raw)==tensor['bytes'] and tensor['address']==manifest['outputs'][tensor['node']]['address'],'检测头布局不符')
                f.seek(tensor['address']);f.write(raw)
    install_blocks(image,blocks);return image


def append_fixture(directory,info,blocks,report,records,summary):
    initial={}
    for address,data in blocks.items():
        checked(address%16==0 and len(data)%16==0,'AIP1块未对齐')
        for offset in range(0,len(data),16):
            a=address+offset;checked(a not in initial,'AIP1块重叠');initial[a]=int.from_bytes(data[offset:offset+16],'little')
    expected=initial.copy()
    for address,data in ((REPORT,report),(OUTPUT,records)):
        for offset in range(0,len(data),16):expected[address+offset]=int.from_bytes(data[offset:offset+16],'little')
    # 不覆盖网络原有请求/报告；完整张量黄金记录保留，只追加保留区数据。
    with (directory/'initial.mem').open() as f:
        for line in f:checked(int(line[:8],16) not in initial,'AIP1与已有初值重叠')
    with (directory/'initial.mem').open('a') as f:
        for a,v in sorted(initial.items()):f.write(f'{(a<<128)|v:040x}\n')
    with (directory/'golden.mem').open('a') as f:
        for a,v in sorted(expected.items()):f.write(f'{(a<<256)|(MASK<<128)|v:072x}\n')
    info['initial']+=len(initial);info['golden']+=len(expected)
    info['slots']=1<<max(8,(2*info['initial']-1).bit_length())
    info['postprocess']=dict(summary,output_address=OUTPUT,output_bytes=len(records),report_code=struct.unpack_from('<I',report)[0])


def add_real_postprocess(out,directory,info,reference,max_detections=300,threshold=16384):
    tools=build_tools(out,reference);blocks=make_blocks(json.loads((out/'heads.json').read_text()),max_detections,threshold)
    image=real_image(out,directory,blocks)
    original=json.loads((out/'detections.json').read_text()) if max_detections==300 else None
    report,records,summary=host_check(directory,image,tools,original)
    append_fixture(directory,info,blocks,report,records,summary)
    # 外部加载端只需此64KiB请求/后处理区，加原model.bin；这里绝不包含C检测头黄金值。
    request=bytearray((out/'request.bin').read_bytes());checked(len(request)==MODEL,'AIR1请求区长度错误')
    for address,data in blocks.items():request[address:address+len(data)]=data
    (directory/'request_detection.bin').write_bytes(request)
    (directory/'postprocess_config.bin').write_bytes(blocks[CONFIG])
    (directory/'postprocess_heads.bin').write_bytes(blocks[HEADS])
    (directory/'postprocess_lut.bin').write_bytes(blocks[LUT])
    return [f'+POST_ENABLE=1',f'+POST_OUTPUT_ADDR={OUTPUT}',f'+POST_OUTPUT_BYTES={len(records)}']
