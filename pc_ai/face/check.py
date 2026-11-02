"""短自检：预处理、WIDER边界、浮点/QAT反向、检查点及新权重的首层C对拍。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import sys

import numpy as np
from PIL import Image
import torch

from . import OUTPUTS, PROJECT
from .assets import read_y26f
from .data import board_pool, divide240_even, wider_records, FaceDataset, collate
from .evaluate import metrics
from .model import build_model, check_structure, initialize_from_bin, load_checkpoint
from .prepare_wider import prepare
from .train import save
from .vendor import qat


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference', type=Path, default=PROJECT.parent / 'materials/TridentVision')
    args = p.parse_args()
    torch.set_num_threads(2); torch.manual_seed(7)
    begin = time.monotonic(); result = {}
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    sums = np.arange(61201, dtype=np.uint32)
    assert np.array_equal(divide240_even(sums), np.rint(sums.astype(np.float64) / 240).astype(np.uint8))
    # 独立切片核对窗口边界、RGB顺序与三次重叠/一次不重叠的垂直行为。
    y, x = np.indices((1080, 1920), dtype=np.int32)
    rgb = np.stack([(x + y) % 256, (3 * x + y) % 256, (x + 7 * y) % 256], axis=2).astype(np.uint8)
    pooled = board_pool(Image.fromarray(rgb))
    for oy in (0, 1, 2, 3, 4, 95):
        for ox in (0, 1, 47, 95):
            top, bottom = oy * 1080 // 96, ((oy + 1) * 1080 + 95) // 96
            expected = np.rint(rgb[top:bottom, ox * 20:(ox + 1) * 20].mean(axis=(0, 1))).astype(np.uint8)
            assert np.array_equal(pooled[oy, ox], expected)
    result['preprocess'] = dict(passed=True, mean240_values=61201, independent_windows=24)

    with tempfile.TemporaryDirectory(prefix='face_check_', dir=OUTPUTS) as folder:
        temp = Path(folder); raw = temp / 'raw'
        (raw / 'wider_face_split').mkdir(parents=True)
        for split, directory in [('train', 'WIDER_train'), ('val', 'WIDER_val')]:
            (raw / directory / 'images/event').mkdir(parents=True)
            Image.fromarray(rgb[::16, ::16]).save(raw / directory / 'images/event/face.png')
            Image.new('RGB', (40, 30), (20, 40, 60)).save(raw / directory / 'images/event/empty.png')
            Image.new('RGB', (40, 30)).save(raw / directory / 'images/event/empty2.png')
            # 包含一条有效框、一条invalid框，以及两种合法零框编码。
            annotation = ('event/face.png\n2\n10 8 30 20 0 0 0 0 0 0\n5 5 10 10 0 0 0 1 0 0\n'
                          'event/empty.png\n0\n0 0 0 0 0 0 0 0 0 0\nevent/empty2.png\n0\n')
            (raw / 'wider_face_split' / f'wider_face_{split}_bbx_gt.txt').write_text(annotation)
        manifest = prepare(raw, temp / 'dataset')
        ds = FaceDataset(manifest, 'train')
        assert len(ds) == 3 and ds[0]['cls'].shape == (1, 1) and ds[1]['cls'].shape == (0, 1)
        batch = collate([ds[0], ds[1]])
        assert batch['img'].shape == (2, 3, 96, 96) and batch['batch_idx'].tolist() == [0.]
        bad = temp / 'invalid.txt'; bad.write_text('event/bad.png\n1\n1 2 3\n')
        try:
            list(wider_records(bad))
            raise AssertionError('truncated annotations accepted')
        except ValueError:
            pass
        result['dataset'] = dict(passed=True, invalid_box_filtered=True, empty_images_supported=True)

        asset = read_y26f(args.reference / 'training/export/rearch_int8.bin')
        model = build_model()
        result['structure'] = check_structure(model, asset)
        result['initialization'] = initialize_from_bin(model, asset)
        optimizer = torch.optim.SGD(model.parameters(), lr=0.0001, momentum=0.9)
        losses = []
        for quantized in (False, True):
            if quantized:
                qat.apply_qat(model, verbose=False)
            model.train(); optimizer.zero_grad(set_to_none=True)
            loss, _ = model.loss(batch); loss = loss.sum() / 2
            assert torch.isfinite(loss)
            loss.backward()
            grad = model.model[0].conv.weight.grad
            assert torch.isfinite(grad).all() and bool(grad.abs().sum() > 0)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 10, error_if_nonfinite=True)
            optimizer.step(); losses.append(float(loss.detach()))
        assert all(torch.isfinite(v).all() for v in model.state_dict().values() if v.is_floating_point())
        for name, value in model.state_dict().items():
            if name.endswith('_fq_thr'):
                assert float(value) > 0, name
        model.eval()
        with torch.no_grad():
            predictions = model(batch['img'])[0]
            assert predictions.shape == (2, 189, 6) and torch.isfinite(predictions).all()
        ckpt = temp / 'synthetic_qat.pt'
        dummy_args = argparse.Namespace(epochs=2, qat_start=1, batch=2, lr=0.0001, max_batches=1, val_batches=1, seed=7)
        save(ckpt, model, optimizer, 1, dummy_args, hashlib.sha256(manifest.read_bytes()).hexdigest(),
             {'float': 0., 'qat': 0.}, result['initialization'])
        restored, ck = load_checkpoint(ckpt); restored.eval()
        assert ck['qat'] and all(torch.equal(value, restored.state_dict()[key]) for key, value in model.state_dict().items())
        result['training_interface'] = dict(passed=True, synthetic_steps=2, losses=losses,
                                           checkpoint_roundtrip=True, face_training_run=False)
        # 真正调用训练CLI两次单步epoch，并检查续训路径；数据全为合成小样本。
        from . import train as training
        old_argv, old_output = sys.argv, training.OUTPUTS
        try:
            training.OUTPUTS = temp
            cli = ['face_train', '--data', str(manifest), '--weights-bin',
                   str(args.reference / 'training/export/rearch_int8.bin'), '--epochs', '2', '--qat-start', '1',
                   '--batch', '2', '--workers', '0', '--device', 'cpu', '--allow-cpu',
                   '--max-batches', '1', '--val-batches', '1', '--name', 'synthetic_cli', '--run']
            sys.argv = cli
            training.main()
            last = temp / 'runs/synthetic_cli/last.pt'
            _, cli_ck = load_checkpoint(last)
            assert cli_ck['qat'] and cli_ck['epoch'] == 1 and not cli_ck['training_complete']
            assert (temp / 'runs/synthetic_cli/best_float.pt').is_file()
            assert (temp / 'runs/synthetic_cli/best_qat.pt').is_file()
            sys.argv = [*cli, '--resume', str(last)]
            training.main()
            result['training_cli'] = dict(passed=True, synthetic_epochs=2, batches_per_epoch=1,
                                         float_to_qat=True, resume_loaded=True, real_face_training=False)
        finally:
            sys.argv, training.OUTPUTS = old_argv, old_output
        report = metrics([(0.9, True), (0.8, False), (0.7, True)], 2)
        assert report['true_positives'] == 2 and report['false_positives'] == 1 and report['recall'] == 1

        # 对新QAT权重导出的第一层，独立运行原C算子；不启动完整96²整数网络。
        from .vendor import rearch_export as exporter
        exporter.build_wq_and_scales(restored)
        inp = ((np.arange(3 * 5 * 7).reshape(3, 5, 7) * 7) % 256).astype(np.int16)
        expect = exporter.conv_layer(inp, [(0, 3, 1 / 255)], 'model.0', k=3, s=2)
        exporter.write_bin(temp / 'one_layer.bin')
        test_c = '''#define main unused_reference_main
#include TRIDENT_SOURCE
#undef main
int main(int argc,char **argv){
  if(argc!=3)return 2;load_bin(argv[1]);Tensor x=t_alloc(3,5,7);
  for(int i=0;i<105;i++)x.d[i]=(i*7)%256;
  Tensor y=conv_layer(&x,"model.0");FILE *f=fopen(argv[2],"wb");
  if(!f)return 3;fwrite(y.d,2,(size_t)y.c*y.h*y.w,f);fclose(f);return 0;
}
'''
        (temp / 'one_layer.c').write_text(test_c)
        compiled = subprocess.run(['gcc', '-O2', '-std=c11', '-DTRIDENT_SOURCE=' + json.dumps(str((args.reference / 'training/export/rearch_fixed.c').resolve())),
                        '-I', str(args.reference / 'c_model'), str(temp / 'one_layer.c'), '-lm', '-o', str(temp / 'one_layer')], capture_output=True, text=True)
        (OUTPUTS / 'check_c_compile.log').write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError('首层C检查编译失败，见check_c_compile.log')
        subprocess.run([str(temp / 'one_layer'), str(temp / 'one_layer.bin'), str(temp / 'actual.bin')], check=True)
        actual = np.fromfile(temp / 'actual.bin', dtype='<i2').reshape(expect.shape)
        assert np.array_equal(expect, actual)
        result['new_weights_first_conv'] = dict(passed=True, output_values=actual.size, numpy_c_exact=True)
        # 检查正式导出入口在不加--run时只预检，不偷偷运行全网。
        subprocess.run([sys.executable, '-m', 'pc_ai.face.export', '--checkpoint', str(ckpt),
                        '--reference', str(args.reference)], cwd=PROJECT, check=True, stdout=subprocess.PIPE, text=True)
    result.update(passed=True, seconds=time.monotonic() - begin,
                  gpu_training_verified=False, full_integer_export_verified=False, face_accuracy_verified=False)
    path = OUTPUTS / 'checks.json'; path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('PASS face training interfaces, board preprocessing, QAT/backward, checkpoint, new-weight C conv')
    print('短自检结果：', path)


if __name__ == '__main__':
    main()
