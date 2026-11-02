"""把已下载的WIDER FACE转为与板端预处理一致的96像素缓存；不自动下载大文件。"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from . import OUTPUTS
from .data import board_pool, wider_records
from .model import PREPROCESS


def prepare(root, out, limit=0):
    root, out = Path(root).expanduser().resolve(), Path(out).resolve()
    config = dict(schema=1, preprocess=PREPROCESS, active_classes={'0': 'face'},
                  source_root=str(root), splits={}, annotations={}, statistics={})
    for split, directory in [('train', 'WIDER_train'), ('val', 'WIDER_val')]:
        annotation = root / 'wider_face_split' / f'wider_face_{split}_bbx_gt.txt'
        if not annotation.is_file():
            raise FileNotFoundError(annotation)
        config['annotations'][split] = hashlib.sha256(annotation.read_bytes()).hexdigest()
        rows, sizes = [], []
        dest = out / split
        dest.mkdir(parents=True, exist_ok=True)
        for relative, raw_boxes in wider_records(annotation):
            path = root / directory / 'images' / relative
            with Image.open(path) as image:
                width, height = image.size
                boxes = []
                for x, y, w, h in raw_boxes:
                    x1, y1, x2, y2 = max(0, x), max(0, y), min(width, x + w), min(height, y + h)
                    if x2 <= x1 or y2 <= y1:
                        continue
                    boxes.append([(x1 + x2) / (2 * width), (y1 + y2) / (2 * height),
                                  (x2 - x1) / width, (y2 - y1) / height])
                    sizes.append(min((x2 - x1) / width, (y2 - y1) / height) * 96)
                cached = board_pool(image)
            tensor = f'{split}/{len(rows):06d}.npy'
            np.save(out / tensor, cached, allow_pickle=False)
            rows.append(dict(tensor=tensor, source=relative, original_shape=[height, width], boxes=boxes))
            if len(rows) % 500 == 0:
                print(f'{split}: {len(rows)} images cached', flush=True)
            if limit and len(rows) >= limit:
                break
        config['splits'][split] = rows
        config['statistics'][split] = dict(images=len(rows), faces=len(sizes),
            empty_images=sum(not r['boxes'] for r in rows),
            faces_smaller_than_4_input_pixels=sum(s < 4 for s in sizes),
            note='保留有效小脸；此统计用于评估96输入的能力边界，不代表可可靠检测这些脸')
    (out / 'dataset.json').write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(config['statistics'], ensure_ascii=False, indent=2))
    return out / 'dataset.json'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True, help='包含WIDER_train/WIDER_val/wider_face_split的目录')
    p.add_argument('--out', type=Path, default=OUTPUTS / 'wider96')
    p.add_argument('--limit', type=int, default=0, help='每个划分最多处理的图片数；0为全部')
    p.add_argument('--run', action='store_true', help='显式开始可能较久的全量图片缓存')
    args = p.parse_args()
    if args.limit < 0:
        p.error('--limit不能为负')
    if not args.run:
        print('尚未处理图片。确认数据目录后加 --run；输出目录：', args.out)
        return
    print(prepare(args.root, args.out, args.limit))


if __name__ == '__main__':
    main()
