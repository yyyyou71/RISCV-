"""用训练检查点预览人脸框，使用与板端匹配的预处理，不附加NMS。"""
import argparse
import json
from pathlib import Path

from PIL import ImageDraw
import torch

from . import OUTPUTS
from .data import board_pool
from .model import load_checkpoint
from pc_ai.verify_trident import collect_images, load_rgb


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--checkpoint', type=Path, required=True)
    p.add_argument('--image', type=Path, action='append', required=True)
    p.add_argument('--out', type=Path, default=OUTPUTS / 'predictions')
    p.add_argument('--threshold', type=float, default=0.25)
    p.add_argument('--limit', type=int, default=8, help='0为全部图片')
    p.add_argument('--device', default='cpu')
    args = p.parse_args()
    if not 0 <= args.threshold <= 1 or args.limit < 0:
        p.error('阈值须在0..1内，limit不能为负')
    args.out.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4)
    model, _ = load_checkpoint(args.checkpoint, args.device); model.eval()
    images, skipped = collect_images(args.image, args.out)
    (args.out / 'skipped_images.json').write_text(json.dumps(skipped, ensure_ascii=False, indent=2) + '\n')
    results = []
    with torch.no_grad():
        for index, path in enumerate(images[:args.limit] if args.limit else images):
            image = load_rgb(path)
            tensor = torch.from_numpy(board_pool(image).copy()).permute(2, 0, 1).unsqueeze(0).float().to(args.device) / 255
            output = model(tensor)
            detections = (output[0] if isinstance(output, tuple) else output)[0].cpu().numpy()
            draw, rows = ImageDraw.Draw(image), []
            for x1, y1, x2, y2, score, cls in detections:
                if cls != 0 or score < args.threshold:
                    continue
                box = [float(x1) * image.width / 96, float(y1) * image.height / 96,
                       float(x2) * image.width / 96, float(y2) * image.height / 96]
                if box[2] <= box[0] or box[3] <= box[1]:
                    continue
                draw.rectangle(box, outline='red', width=3)
                draw.text((box[0], box[1]), f'face {float(score):.3f}', fill='red')
                rows.append(dict(box=box, score=float(score), cls=0))
            target = args.out / f'{index:04d}_{path.stem}.png'; image.save(target)
            results.append(dict(source=str(path), preview=str(target), detections=rows))
            print(target, len(rows), 'faces', flush=True)
    (args.out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
