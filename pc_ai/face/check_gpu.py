"""CUDA小张量前向/反向检查，不训练模型、不下载依赖。"""
import argparse
import json
import shutil
import subprocess

import torch

from . import OUTPUTS


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--require-cuda', action='store_true')
    args = p.parse_args()
    report = dict(torch=torch.__version__, torch_cuda=torch.version.cuda,
                  cuda_available=torch.cuda.is_available(), driver=None, devices=[], cuda_test_passed=False)
    if shutil.which('nvidia-smi'):
        cmd = subprocess.run(['nvidia-smi', '--query-gpu=name,memory.total,driver_version', '--format=csv,noheader'],
                             capture_output=True, text=True, timeout=15)
        report['driver'] = cmd.stdout.strip() if cmd.returncode == 0 else cmd.stderr.strip()
    if report['cuda_available']:
        for n in range(torch.cuda.device_count()):
            properties = torch.cuda.get_device_properties(n)
            report['devices'].append(dict(name=properties.name, bytes=properties.total_memory,
                                          compute_capability=list(torch.cuda.get_device_capability(n))))
        x = torch.randn(16, 16, device='cuda', requires_grad=True)
        x.square().mean().backward(); torch.cuda.synchronize()
        report['cuda_test_passed'] = bool(torch.isfinite(x.grad).all())
    out = OUTPUTS / 'gpu.json';out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.require_cuda and not report['cuda_test_passed']:
        raise SystemExit('CUDA尚未就绪；先安装驱动并重启，再安装requirements-gpu.txt')


if __name__ == '__main__':
    main()
