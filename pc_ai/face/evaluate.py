"""单类face的验证集AP50与固定阈值precision/recall；不是官方WIDER评测。"""
import numpy as np
import torch


def iou(box, boxes):
    low = np.maximum(box[:2], boxes[:, :2])
    high = np.minimum(box[2:], boxes[:, 2:])
    intersection = np.maximum(high - low, 0).prod(axis=1)
    area = np.maximum(box[2:] - box[:2], 0).prod()
    other = np.maximum(boxes[:, 2:] - boxes[:, :2], 0).prod(axis=1)
    return intersection / np.maximum(area + other - intersection, 1e-12)


def metrics(samples, gt_count, threshold=0.25):
    samples = sorted(samples, key=lambda r: -r[0])
    if not samples:
        return dict(ap50=0., precision=0., recall=0., true_positives=0, false_positives=0, targets=gt_count)
    scores = np.asarray([r[0] for r in samples])
    hits = np.asarray([r[1] for r in samples], dtype=np.float64)
    tp, fp = hits.cumsum(), (1 - hits).cumsum()
    recall = tp / max(gt_count, 1)
    precision = tp / np.maximum(tp + fp, 1)
    ap = float(np.mean([precision[recall >= r].max(initial=0) for r in np.linspace(0, 1, 101)])) if gt_count else 0.
    selected = scores >= threshold
    hits_at_threshold = int(hits[selected].sum())
    false_at_threshold = int(selected.sum()) - hits_at_threshold
    return dict(ap50=ap, precision=hits_at_threshold / max(int(selected.sum()), 1),
                recall=hits_at_threshold / max(gt_count, 1), true_positives=hits_at_threshold,
                false_positives=false_at_threshold, targets=gt_count)


@torch.no_grad()
def evaluate(model, loader, device, limit_batches=0, threshold=0.25):
    model.eval()
    samples, targets, frames = [], 0, 0
    for step, batch in enumerate(loader):
        output = model(batch['img'].to(device))
        output = output[0] if isinstance(output, tuple) else output
        output = output.detach().cpu().numpy()
        for b, detections in enumerate(output):
            xywh = batch['bboxes'][batch['batch_idx'] == b].numpy() * 96
            gt = np.concatenate([xywh[:, :2] - xywh[:, 2:] / 2, xywh[:, :2] + xywh[:, 2:] / 2], axis=1)
            targets += len(gt); frames += 1
            used = np.zeros(len(gt), dtype=bool)
            detections = detections[(detections[:, 5] == 0) & (detections[:, 4] >= 0.001)]
            detections = detections[np.argsort(-detections[:, 4], kind='stable')]
            for d in detections:
                match = False
                if len(gt):
                    overlaps = iou(d[:4], gt)
                    overlaps[used] = -1
                    best = int(overlaps.argmax())
                    if overlaps[best] >= 0.5:
                        used[best] = True; match = True
                samples.append((float(d[4]), match))
        if limit_batches and step + 1 >= limit_batches:
            break
    result = metrics(samples, targets, threshold)
    result.update(frames=frames, score_threshold=threshold,
                  evaluated_classes=[0], kind='single-class AP50 on pooled validation; not official WIDER AP')
    return result
