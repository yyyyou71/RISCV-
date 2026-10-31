"""Build a contiguous board DDR upload image, without running inference."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'pc_ai'))
from postprocess_tools import make_blocks


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--prepared',type=Path,default=ROOT/'build/integration-review/model_prepared')
    p.add_argument('--output',type=Path,default=ROOT/'build/board-ai/board_model.bin')
    p.add_argument('--threshold',type=int,default=16384)
    args=p.parse_args()
    model=(args.prepared/'model.bin').read_bytes();h=struct.unpack_from('<16I',model)
    if h[:5]!=(0x314d4941,2,64,64,99) or h[6]!=0x10000 or h[7]!=0x10000+len(model) or h[7]>0x02000000:
        raise ValueError('Expected the 99-task W8A16 model fitting the low 32MiB board arena')
    if h[9]!=294912 or h[13]!=1:raise ValueError('Expected 96x96 RGB INT16 input')
    heads=json.loads((args.prepared/'heads.json').read_text())
    if heads['engine_input_shape']!=[96,96,3] or len(heads['heads'])!=3:raise ValueError('Unexpected detection profile')
    image=bytearray(0x10000);image.extend(model)
    for address,data in make_blocks(heads,threshold=args.threshold).items():
        if address+len(data)>0x10000:raise ValueError('Postprocess metadata outside prefix')
        image[address:address+len(data)]=data
    fnv=2166136261
    for value in image:fnv=((fnv^value)*16777619)&0xffffffff
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_bytes(image)
    report=dict(schema=1,bytes=len(image),fnv1a32=f'{fnv:08x}',sha256=hashlib.sha256(image).hexdigest(),
                model_address=0x10000,model_sha256=hashlib.sha256(model).hexdigest(),tasks=99,
                postprocess_address=0x5000,head_pairs=3,head_tensors=6,max_detections=300,threshold_q16=args.threshold,
                live_input_address=0x03f00000,inference_run=False,
                note='Upload the entire file at logical DDR offset 0; original input is rebound at runtime.')
    args.output.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n')
    (ROOT/'reports/preprocess/board_model.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'Board model ready: {len(image)} bytes / 99 tasks / six head tensors; no inference run')


if __name__=='__main__':main()
