"""按整张图片筛选近景人脸数据，复用已有96像素缓存，不启动训练。"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path

from . import OUTPUTS


def select_rows(rows, min_face_side=8., max_faces=5):
    """保留全部有效框均足够大的图片；不单独删框，避免制造漏标背景。"""
    selected = []
    rejected = dict(too_many_faces=0, small_faces=0)
    for row in rows:
        boxes = row['boxes']
        if len(boxes) > max_faces:
            rejected['too_many_faces'] += 1
        elif any(min(box[2], box[3]) * 96 + 1e-9 < min_face_side for box in boxes):
            rejected['small_faces'] += 1
        else:
            # 原有空标注图片原样保留，不通过删除小脸框产生新的空标注。
            selected.append(row)
    return selected, rejected


def prepare_subset(manifest, out, min_face_side=8., max_faces=5, run=False):
    if not math.isfinite(min_face_side) or not 0 < min_face_side <= 96 or max_faces < 1:
        raise ValueError('min-face-side须在(0,96]范围内，max-faces须至少为1')
    manifest, out = Path(manifest).expanduser().resolve(), Path(out).expanduser().resolve()
    target = out / 'dataset.json'
    if target == manifest:
        raise ValueError('子集必须写到单独目录，不能覆盖原始数据清单')
    original_bytes = manifest.read_bytes()
    original = json.loads(original_bytes)
    if (original.get('schema') != 1 or original.get('active_classes') != {'0': 'face'} or
            original.get('preprocess') != 'hdmi1920x1080-adaptive96-rne-rgb-v1'):
        raise ValueError('输入须为当前板端96x96预处理的face数据清单')
    config = {key: value for key, value in original.items() if key not in ('splits', 'statistics', 'selection')}
    config.update(splits={}, statistics={}, selection=dict(
        kind='whole-image close-face subset',
        source_manifest=os.path.relpath(manifest, out),
        source_manifest_sha256=hashlib.sha256(original_bytes).hexdigest(),
        min_face_side_input_pixels=min_face_side, max_valid_faces_per_image=max_faces,
        keep_existing_empty_images=True, drop_individual_boxes=False,
        preserve_source_train_val_split=True))
    for split in ('train', 'val'):
        rows = original['splits'][split]
        selected, rejected = select_rows(rows, min_face_side, max_faces)
        if not selected or not any(row['boxes'] for row in selected):
            raise ValueError(f'{split}筛选后没有有效人脸，请放宽筛选条件')
        result = []
        for row in selected:
            tensor = (manifest.parent / row['tensor']).resolve()
            if not tensor.is_file():
                raise FileNotFoundError(tensor)
            # 只生成新清单；张量仍引用原缓存，不复制、不重新预处理。
            result.append(dict(row, tensor=os.path.relpath(tensor, out)))
        config['splits'][split] = result
        sides = [min(box[2], box[3]) * 96 for row in result for box in row['boxes']]
        config['statistics'][split] = dict(
            input_images=len(rows), images=len(result), faces=len(sides),
            empty_images=sum(not row['boxes'] for row in result),
            faces_smaller_than_4_input_pixels=sum(side < 4 for side in sides),
            minimum_face_short_side=min(sides), rejected_images=rejected,
            note='仅对有效标注按整图筛选；每张保留图片的全部有效框不变')
    if run:
        content = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
        if target.exists() and target.read_text() != content:
            raise FileExistsError('目标已有不同的数据清单，请更换--out，避免改变已有训练的数据')
        if not target.exists():
            out.mkdir(parents=True, exist_ok=True)
            temp = target.with_suffix('.tmp')
            temp.write_text(content)
            temp.replace(target)
    print(json.dumps(config['statistics'], ensure_ascii=False, indent=2))
    print(('已生成：' if run else '仅预览，未写入；加--run生成：'), target)
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, default=OUTPUTS / 'wider96/dataset.json')
    parser.add_argument('--out', type=Path, default=OUTPUTS / 'wider96_close')
    parser.add_argument('--min-face-side', type=float, default=8., help='96输入中每个有效框的宽和高至少为此像素数')
    parser.add_argument('--max-faces', type=int, default=5, help='每张图片最多有效人脸框数')
    parser.add_argument('--run', action='store_true', help='只写新数据清单，不启动训练')
    args = parser.parse_args()
    prepare_subset(args.data, args.out, args.min_face_side, args.max_faces, args.run)


if __name__ == '__main__':
    main()
