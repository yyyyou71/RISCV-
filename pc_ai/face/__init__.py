"""保持已上板 REARCH-v1 结构的人脸检测训练工具。"""
import os
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
OUTPUTS = PROJECT / 'pc_ai/outputs/face'
for key, folder in [('YOLO_CONFIG_DIR', 'ultralytics'), ('MPLCONFIGDIR', 'matplotlib')]:
    path = OUTPUTS / folder
    path.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault(key, str(path))
os.environ.setdefault('OMP_NUM_THREADS', '4')
