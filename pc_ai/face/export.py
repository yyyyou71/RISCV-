"""QAT检查点→Y26F→AIM1/AIP1→板端SPI镜像；只有--run才执行完整整数导出。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

import numpy as np
import torch

from . import OUTPUTS, PROJECT
from .assets import read_y26f
from .model import load_checkpoint, check_structure, PROFILE, PREPROCESS


def board_image(prepared, output, threshold):
    from pc_ai.postprocess_tools import make_blocks
    model = (prepared / 'model.bin').read_bytes()
    h = struct.unpack_from('<16I', model)
    if (h[:5] != (0x314d4941, 2, 64, 64, 99) or h[6] != 0x10000 or
            h[7] != 0x10000 + len(model) or h[7] > 0x02000000 or h[9] != 294912 or h[13] != 1):
        raise ValueError('导出结果不符合ziguang板端99任务/96输入配置')
    heads = json.loads((prepared / 'heads.json').read_text())
    if heads['engine_input_shape'] != [96, 96, 3] or len(heads['heads']) != 3:
        raise ValueError('检测头配置不符')
    image = bytearray(0x10000) + model
    for address, data in make_blocks(heads, threshold=threshold).items():
        if address + len(data) > 0x10000:
            raise ValueError('后处理元数据超出前缀区域')
        image[address:address + len(data)] = data
    output.write_bytes(image)
    fnv = 2166136261
    for byte in image:
        fnv = ((fnv ^ byte) * 16777619) & 0xffffffff
    return dict(bytes=len(image), sha256=hashlib.sha256(image).hexdigest(), fnv1a32=f'{fnv:08x}',
                model_address=0x10000, live_input_address=0x03f00000, tasks=99, threshold_q16=threshold)


def compare_numpy_c(exported, prepared):
    graph = json.loads((prepared / 'graph.json').read_text())
    checked, values = 0, 0
    for n in graph['nodes']:
        expected = exported / 'golden_int/face96' / (n['name'] + '.npy')
        if not expected.is_file():
            continue  # pool/cat/up不在原训练导出器的83个注册点中，仍由C/RTL任务链覆盖。
        h, w, c = n['shape']
        raw = np.fromfile(prepared / 'golden' / f'layer{n["index"]:03d}.bin', dtype='<i2')
        actual = raw.reshape(h, w, (c + 15) & ~15)[:, :, :c].transpose(2, 0, 1)
        target = np.load(expected, allow_pickle=False)
        if actual.shape != target.shape or not np.array_equal(actual, target):
            raise ValueError('NumPy整数导出/C模型逐值不符：' + n['name'])
        checked += 1; values += actual.size
    if checked != 82:
        raise ValueError('必须覆盖72卷积及10ADD注册点')
    return dict(passed=True, intermediate_points=checked, values=values, full_rtl_run=False)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--checkpoint', type=Path, required=True)
    p.add_argument('--reference', type=Path, default=PROJECT.parent / 'materials/TridentVision')
    p.add_argument('--out', type=Path, default=OUTPUTS / 'deploy')
    p.add_argument('--threshold', type=int, default=16384, help='Q0.16分数阈值，默认0.25')
    p.add_argument('--run', action='store_true', help='执行完整整数导出与C对拍，可能较久')
    args = p.parse_args()
    if not 0 <= args.threshold <= 65535:
        p.error('threshold须为0..65535')
    torch.set_num_threads(4)
    model, ck = load_checkpoint(args.checkpoint)
    if not ck['qat']:
        raise ValueError('需要best_qat.pt，不能把浮点阶段的检查点直接部署')
    asset = read_y26f(args.reference / 'training/export/rearch_int8.bin')
    structure = check_structure(model, asset)
    for k, value in model.state_dict().items():
        if value.is_floating_point() and not torch.isfinite(value).all():
            raise ValueError('检查点含非有限值：' + k)
        if k.endswith('_fq_thr') and float(value) <= 0:
            raise ValueError('未得到有效激活量化范围：' + k)
    if not args.run:
        print(json.dumps(dict(checkpoint_checked=True, structure=structure, export_started=False,
                              output=str(args.out), note='加--run才开始完整整数导出与C对拍'), ensure_ascii=False, indent=2))
        return
    from .vendor import rearch_export as exporter
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    (out / 'deployment.json').unlink(missing_ok=True)
    # 复用原整数数学，只把模型加载交给本入口，避免路径和检查点元数据失配。
    exporter.load_model = lambda path: (model.eval(), ck)
    original_argv = sys.argv
    try:
        sys.argv = ['rearch_export', '--ckpt', str(args.checkpoint.resolve()), '--out', str(out / 'quantized'), '--tag', 'face96']
        exporter.main()
    finally:
        sys.argv = original_argv
    exp = json.loads((out / 'quantized/export_report.json').read_text())
    if (exp['isa_violations'] or any(exp['y13_clamp'].values()) or
            any(not v['int48_ok'] for v in exp['overflow'].values())):
        raise ValueError('整数导出范围/算子检查失败，禁止生成板端镜像')
    ref = out / 'reference'
    (ref / 'training/export').mkdir(parents=True, exist_ok=True)
    (ref / 'c_model').mkdir(exist_ok=True)
    shutil.copyfile(args.reference / 'training/export/rearch_fixed.c', ref / 'training/export/rearch_fixed.c')
    shutil.copyfile(args.reference / 'c_model/lut_tables.h', ref / 'c_model/lut_tables.h')
    shutil.copyfile(out / 'quantized/rearch_int8.bin', ref / 'training/export/rearch_int8.bin')
    yy, xx = np.meshgrid(np.arange(96), np.arange(96), indexing='ij')
    diagnostic = np.stack([(xx + yy + c * 37) % 256 for c in range(3)]).astype('<i2')
    np.save(out / 'diagnostic.npy', diagnostic, allow_pickle=False)
    prepared = out / 'prepared'
    subprocess.run([sys.executable, str(PROJECT / 'pc_ai/prepare_trident_network.py'), '--reference', str(ref),
                    '--out', str(prepared), '--input', str(out / 'diagnostic.npy'), '--golden'], check=True, cwd=PROJECT)
    agreement = compare_numpy_c(out / 'quantized', prepared)
    image = board_image(prepared, out / 'board_model.bin', args.threshold)
    result = dict(schema=1, profile=PROFILE, preprocess=PREPROCESS, checkpoint=str(args.checkpoint.resolve()),
        checkpoint_sha256=hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
        active_classes={'0': 'face'}, physical_classes=80, numpy_c_agreement=agreement, board_image=image,
        trained_epoch=ck['epoch'], trained_dataset=ck['dataset_sha256'], best_validation=ck['best'],
        full_network_rtl_verified=False, board_verified=False, face_accuracy_accepted=False,
        note='整数导出/C对拍通过仍不等于人脸精度或当前板端RTL已验收')
    (out / 'deployment.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('板端SPI镜像：', out / 'board_model.bin')
    print('部署报告：', out / 'deployment.json')


if __name__ == '__main__':
    main()
