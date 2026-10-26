#!/usr/bin/env python3
"""快速检查 Conda YOLO 推理环境；不下载权重、不启动训练或完整网络推理。"""
import importlib.metadata
import json
import os
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'pc_ai/outputs/environment'
os.environ.setdefault('YOLO_CONFIG_DIR',str(OUT/'ultralytics'))
os.environ.setdefault('MPLCONFIGDIR',str(OUT/'matplotlib'))
os.environ.setdefault('OMP_NUM_THREADS','4')


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    for setting in ['YOLO_CONFIG_DIR','MPLCONFIGDIR']:
        Path(os.environ[setting]).expanduser().mkdir(parents=True,exist_ok=True)
    result=dict(python=sys.version,executable=sys.executable,prefix=sys.prefix,
                conda_env=os.environ.get('CONDA_DEFAULT_ENV'),packages={})
    missing=[]
    for name in ['torch','torchvision','ultralytics','numpy','Pillow','opencv-python','scipy']:
        try:result['packages'][name]=importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:missing.append(name)
    result['missing']=missing
    if missing:
        print('缺少依赖：'+', '.join(missing))
        (OUT/'environment.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
        return 1
    try:
        import torch
        import torchvision
        import ultralytics
        import cv2
        import numpy as np
        import scipy
        # 验证二进制库可导入且 CPU 张量运算正常，不执行 YOLO 网络。
        values=torch.arange(4,dtype=torch.float32).reshape(2,2)
        assert torch.equal(values@torch.eye(2),values)
        result['cuda_available']=torch.cuda.is_available()
        result['torch_cuda_build']=torch.version.cuda
        result['cpu_tensor_check']=True
        result['imports']={m.__name__:m.__version__ for m in [torch,torchvision,ultralytics,cv2,np,scipy]}
    except Exception as error:
        result['error']=f'{type(error).__name__}: {error}'
        print(result['error'])
        (OUT/'environment.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
        return 1
    (OUT/'environment.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    print('PASS：YOLO CPU 推理依赖和基础张量运算可用。')
    print('Python：'+sys.executable)
    print('PyTorch：'+torch.__version__+'；CUDA 可用：'+str(result['cuda_available']))
    print('这只验证环境，不代表模型结构、权重或检测精度已经验证。')
    return 0


if __name__=='__main__':sys.exit(main())
