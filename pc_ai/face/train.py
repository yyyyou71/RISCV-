"""本地/云GPU共用的人脸训练：先浮点适应，再按原实现进行W8A16 QAT。"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import time

import numpy as np
import torch
from torch.utils.data import DataLoader

from . import OUTPUTS, PROJECT
from .assets import read_y26f
from .data import FaceDataset, collate
from .evaluate import evaluate
from .model import build_model, check_structure, initialize_from_bin, load_checkpoint, PROFILE, PREPROCESS
from .vendor import qat


def save(path, model, optimizer, epoch, args, dataset_sha, best, initialization):
    # 原子替换，避免中断时把last.pt留成半个文件。
    content = dict(schema=1, profile=PROFILE, preprocess=PREPROCESS,
                   model={k: v.detach().cpu().clone() for k, v in model.state_dict().items()},
                   qat=any(k.endswith('_fq_thr') for k in model.state_dict()),
                   optimizer=optimizer.state_dict(), epoch=epoch, args=vars(args),
                   dataset_sha256=dataset_sha, best=best, initialization=initialization,
                   rng=random.getstate(), torch_rng=torch.get_rng_state(),
                   cuda_rng=torch.cuda.get_rng_state_all() if torch.cuda.is_available() else [],
                   active_classes={0: 'face'},
                   training_complete=epoch + 1 == args.epochs and not (args.max_batches or args.val_batches))
    temp = path.with_suffix('.tmp')
    torch.save(content, temp)
    temp.replace(path)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data', type=Path, default=OUTPUTS / 'wider96/dataset.json')
    p.add_argument('--weights-bin', type=Path, default=PROJECT.parent / 'materials/TridentVision/training/export/rearch_int8.bin')
    p.add_argument('--init', type=Path, help='用本入口的检查点微调，保留模型、不恢复优化器')
    p.add_argument('--resume', type=Path, help='同一run续训，恢复优化器/epoch/RNG')
    p.add_argument('--scratch', action='store_true', help='明确选择随机初始化，不使用整数资产近似恢复')
    p.add_argument('--epochs', type=int, default=60)
    p.add_argument('--qat-start', type=int, default=40, help='从零计数的QAT起始epoch；0表示全程QAT')
    p.add_argument('--batch', type=int, default=16)
    p.add_argument('--workers', type=int, default=2)
    p.add_argument('--device', default='cuda:0')
    p.add_argument('--lr', type=float, default=0.002)
    p.add_argument('--seed', type=int, default=20261102)
    p.add_argument('--name', default='face96')
    p.add_argument('--max-batches', type=int, default=0, help='仅用于短自检；0表示每epoch全量')
    p.add_argument('--val-batches', type=int, default=0)
    p.add_argument('--allow-cpu', action='store_true', help='明确允许在CPU上训练；不作为正常GPU训练的静默回退')
    p.add_argument('--run', action='store_true', help='显式启动训练；不带此项只显示计划')
    args = p.parse_args()
    if (args.epochs <= 0 or not 0 <= args.qat_start < args.epochs or args.batch <= 0 or
            args.workers < 0 or args.lr <= 0 or args.max_batches < 0 or args.val_batches < 0):
        p.error('epochs/batch/lr须为正，qat-start须位于训练范围内，workers及步数上限不能为负')
    if sum(bool(v) for v in (args.init, args.resume, args.scratch)) > 1:
        p.error('--init/--resume/--scratch互斥')
    if Path(args.name).name != args.name or args.name in ('', '.', '..'):
        p.error('--name必须是单个目录名')
    run_dir = OUTPUTS / 'runs' / args.name
    if not args.run:
        print(json.dumps(dict(action='prepared_only', profile=PROFILE, preprocess=PREPROCESS,
                              physical_classes=80, face_class=0, output=str(run_dir), args=vars(args)),
                         default=str, ensure_ascii=False, indent=2))
        print('未启动训练。驱动/CUDA及数据准备好后加 --run。')
        return
    if args.device.startswith('cuda') and not torch.cuda.is_available():
        raise RuntimeError('CUDA不可用：当前可能是CPU版PyTorch或驱动未安装。不会自动转为长时间CPU训练。')
    if args.device == 'cpu' and not args.allow_cpu:
        raise RuntimeError('CPU训练须显式加 --allow-cpu，短自检使用face.check即可')
    torch.set_num_threads(4)
    random.seed(args.seed); np.random.seed(args.seed); torch.manual_seed(args.seed)
    dataset_sha = hashlib.sha256(args.data.read_bytes()).hexdigest()
    train_set, val_set = FaceDataset(args.data, 'train', True), FaceDataset(args.data, 'val')
    train_loader = DataLoader(train_set, batch_size=args.batch, shuffle=True, num_workers=args.workers,
                              collate_fn=collate, pin_memory=args.device.startswith('cuda'),
                              persistent_workers=args.workers > 0)
    val_loader = DataLoader(val_set, batch_size=args.batch, num_workers=args.workers, collate_fn=collate,
                            persistent_workers=args.workers > 0)
    run_dir.mkdir(parents=True, exist_ok=True)
    if (run_dir / 'last.pt').exists() and not args.resume:
        raise FileExistsError('该run已有last.pt，请使用--resume或更换--name，避免覆盖')
    start, best, initialization = 0, {'float': -1., 'qat': -1.}, {'method': 'random'}
    if args.resume or args.init:
        model, ck = load_checkpoint(args.resume or args.init, args.device)
        initialization = ck['initialization']
        if args.resume:
            for name in ('epochs', 'qat_start', 'batch', 'lr', 'max_batches', 'val_batches', 'seed'):
                if ck['args'][name] != getattr(args, name):
                    raise ValueError('续训参数必须保持一致：' + name)
            if ck['dataset_sha256'] != dataset_sha:
                raise ValueError('续训数据集manifest发生变化')
            start = ck['epoch'] + 1; best = ck['best']
            random.setstate(ck['rng']); torch.set_rng_state(ck['torch_rng'])
            if ck['cuda_rng'] and torch.cuda.is_available():
                torch.cuda.set_rng_state_all(ck['cuda_rng'])
    else:
        model = build_model('cpu')
        if not args.scratch:
            asset = read_y26f(args.weights_bin)
            initialization = initialize_from_bin(model, asset)
        model.to(args.device)
    if args.weights_bin.is_file():
        check_structure(model, read_y26f(args.weights_bin))
    model.args.epochs = args.epochs
    optimizer = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=5e-4)
    if args.resume:
        optimizer.load_state_dict(ck['optimizer'])
    # 框架的E2E损失包含两训练分支；每epoch更新其one2many/one2one权重。
    model.criterion = model.init_criterion()
    if hasattr(model.criterion, 'update'):
        for _ in range(start):
            model.criterion.update()
    with (run_dir / 'epochs.jsonl').open('a', encoding='utf-8') as log:
        for epoch in range(start, args.epochs):
            if epoch >= args.qat_start and not any(k.endswith('_fq_thr') for k in model.state_dict()):
                qat.apply_qat(model, verbose=True)
            quantized = any(k.endswith('_fq_thr') for k in model.state_dict())
            model.train()
            lr = args.lr * (0.05 + 0.95 * (1 + math.cos(math.pi * epoch / args.epochs)) / 2)
            for group in optimizer.param_groups:
                group['lr'] = lr
            began, loss_sum, images, steps = time.monotonic(), 0., 0, 0
            for step, batch in enumerate(train_loader):
                batch = {k: v.to(args.device, non_blocking=True) for k, v in batch.items()}
                loss, _ = model.loss(batch)
                loss = loss.sum() / len(batch['img'])
                if not torch.isfinite(loss):
                    raise RuntimeError(f'epoch={epoch} step={step}: loss非有限值，未保存损坏检查点')
                optimizer.zero_grad(set_to_none=True); loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 10., error_if_nonfinite=True)
                optimizer.step()
                loss_sum += float(loss.detach()); images += len(batch['img']); steps += 1
                if steps % 50 == 0:
                    print(f'epoch={epoch} step={steps}/{len(train_loader)} loss={loss_sum/steps:.5f}', flush=True)
                if args.max_batches and steps >= args.max_batches:
                    break
            validation = evaluate(model, val_loader, args.device, args.val_batches)
            record = dict(epoch=epoch, qat=quantized, loss=loss_sum / steps, learning_rate=lr,
                          images=images, seconds=time.monotonic() - began, validation=validation)
            print(json.dumps(record, ensure_ascii=False), flush=True)
            log.write(json.dumps(record, ensure_ascii=False) + '\n'); log.flush()
            key = 'qat' if quantized else 'float'
            improved = validation['ap50'] > best[key]
            if improved:
                best[key] = validation['ap50']
            if hasattr(model.criterion, 'update'):
                model.criterion.update()
            save(run_dir / 'last.pt', model, optimizer, epoch, args, dataset_sha, best, initialization)
            if improved:
                save(run_dir / f'best_{key}.pt', model, optimizer, epoch, args, dataset_sha, best, initialization)
    (run_dir / 'completed.json').write_text(json.dumps(dict(epochs=args.epochs, best=best,
        profile=PROFILE, dataset_sha256=dataset_sha, short_run=bool(args.max_batches or args.val_batches),
        accuracy_accepted=False, export_required=True), indent=2) + '\n')
    print('训练结束。先检查验证集画框与AP50，再导出best_qat.pt；训练结束不等于已通过精度验收。')


if __name__ == '__main__':
    main()
