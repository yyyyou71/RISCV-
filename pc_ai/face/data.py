"""与板端1080p→96均值池化对齐的数据入口；缓存后无需逐epoch处理原图。"""
import json
from pathlib import Path

import numpy as np
from PIL import Image
import torch
from torch.utils.data import Dataset

from .model import PREPROCESS


def divide240_even(sums):
    sums = np.asarray(sums, dtype=np.uint32)
    q, r = sums // 240, sums % 240
    return (q + ((r > 120) | ((r == 120) & ((q & 1) != 0)))).astype(np.uint8)


def board_pool(image):
    """原图先铺满1920×1080模拟HDMI整帧，再按板端窗口与ties-to-even生成RGB96。"""
    image = image.convert('RGB').resize((1920, 1080), Image.Resampling.BILINEAR)
    rgb = np.asarray(image, dtype=np.uint8)
    horizontal = rgb.reshape(1080, 96, 20, 3).sum(axis=2, dtype=np.uint32)
    integral = np.concatenate([np.zeros((1, 96, 3), dtype=np.uint32),
                               horizontal.cumsum(axis=0, dtype=np.uint32)])
    start = np.arange(96) * 1080 // 96
    end = ((np.arange(96) + 1) * 1080 + 95) // 96
    if not np.all(end - start == 12):
        raise ValueError('板端每窗口必须是20×12像素')
    return divide240_even(integral[end] - integral[start])


def wider_records(annotation):
    """严格解析官方WIDER FACE文本标注，保留全部有效大小的人脸，不擅自删除小脸。"""
    lines = Path(annotation).read_text(encoding='utf-8').splitlines()
    at = 0
    while at < len(lines):
        relative = lines[at].strip()
        at += 1
        if not relative:
            continue
        relative_path = Path(relative)
        if relative_path.is_absolute() or '..' in relative_path.parts:
            raise ValueError('非法图片相对路径')
        if at >= len(lines):
            raise ValueError('标注缺少框数')
        count = int(lines[at]); at += 1
        if count < 0:
            raise ValueError('标注框数不能为负')
        boxes = []
        # 同时接受零框后带全零占位行、以及直接进入下一图片的文本版本。
        if count == 0:
            if at < len(lines) and len(lines[at].split()) >= 10:
                values = [int(v) for v in lines[at].split()]
                if any(values):
                    raise ValueError('零框占位行必须全零')
                at += 1
            yield relative, boxes
            continue
        for _ in range(count):
            if at >= len(lines):
                raise ValueError('标注文件截断')
            values = lines[at].split(); at += 1
            if len(values) < 10:
                raise ValueError('人脸框需要官方10字段格式')
            values = [int(v) for v in values]
            if count and values[7] == 0 and values[2] > 0 and values[3] > 0:
                boxes.append(values[:4])
        yield relative, boxes


class FaceDataset(Dataset):
    def __init__(self, manifest, split, augment=False):
        manifest = Path(manifest)
        config = json.loads(manifest.read_text())
        if config['preprocess'] != PREPROCESS or config['active_classes'] != {'0': 'face'}:
            raise ValueError('数据集与部署预处理/类别配置不符')
        self.root = manifest.parent
        self.rows = config['splits'][split]
        self.augment = augment
        if not self.rows:
            raise ValueError('数据集划分为空：' + split)

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, index):
        row = self.rows[index]
        image = np.load(self.root / row['tensor'], allow_pickle=False)
        if image.dtype != np.uint8 or image.shape != (96, 96, 3):
            raise ValueError('缓存输入不是96x96 RGB uint8')
        boxes = np.asarray(row['boxes'], dtype=np.float32).reshape(-1, 4).copy()
        if self.augment and bool(torch.rand(()) < 0.5):
            image = image[:, ::-1].copy()
            boxes[:, 0] = 1 - boxes[:, 0]
        img = torch.from_numpy(image.copy()).permute(2, 0, 1).float() / 255
        return dict(img=img, bboxes=torch.from_numpy(boxes),
                    cls=torch.zeros((len(boxes), 1), dtype=torch.float32))


def collate(rows):
    return dict(img=torch.stack([r['img'] for r in rows]),
                bboxes=torch.cat([r['bboxes'] for r in rows]),
                cls=torch.cat([r['cls'] for r in rows]),
                batch_idx=torch.cat([torch.full((len(r['cls']),), i, dtype=torch.float32)
                                     for i, r in enumerate(rows)]))
