"""下载WIDER训练/验证图像与标注，支持断点续传及固定SHA256；只有--run才下载。"""
import argparse
import hashlib
from pathlib import Path
import stat
from urllib.request import Request, urlopen
import zipfile

from . import PROJECT

# CUHK-CSE官方数据仓库的Git-LFS对象大小/哈希，固定到公开提交避免main漂移。
REVISION = '833d07e7bf3860f294242312fe95eed0561eeb17'
FILES = {
    'WIDER_train.zip': (1465602149, 'e23b76129c825cafae8be944f65310b2e1ba1c76885afe732f179c41e5ed6d59'),
    'WIDER_val.zip': (362752168, 'f9efbd09f28c5d2d884be8c0eaef3967158c866a593fc36ab0413e4b2a58a17a'),
    'wider_face_split.zip': (3591642, 'c7561e4f5e7a118c249e0a5c5c902b0de90bbf120d7da9fa28d99041f68a8a5c'),
}


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(4 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def extract(archive, root):
    with zipfile.ZipFile(archive) as z:
        for item in z.infolist():
            target = (root / item.filename).resolve()
            if not target.is_relative_to(root.resolve()) or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError('压缩包含不安全路径/链接')
        z.extractall(root)  # ZipFile读取时同时检查每个成员CRC。


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, default=PROJECT / 'pc_ai/datasets/wider_face')
    p.add_argument('--endpoint', default='https://huggingface.co', help='可显式指定HF镜像；仍校验相同固定SHA256')
    p.add_argument('--run', action='store_true')
    args = p.parse_args()
    if not args.endpoint.startswith('https://'):
        p.error('--endpoint需要HTTPS地址')
    for name, (size, digest) in FILES.items():
        url = f'{args.endpoint.rstrip("/")}/datasets/CUHK-CSE/wider_face/resolve/{REVISION}/data/{name}'
        print(name, size, 'bytes', url, flush=True)
        if not args.run:
            continue
        root = args.root.expanduser().resolve(); root.mkdir(parents=True, exist_ok=True)
        archive = root / name
        if not archive.is_file() or archive.stat().st_size != size or checksum(archive) != digest:
            part = root / (name + '.part')
            offset = part.stat().st_size if part.exists() else 0
            if offset > size:
                raise ValueError(f'{part}比预期文件大，请检查该临时文件')
            if offset == size:
                if checksum(part) != digest:
                    raise ValueError(f'{part}已下载完整但SHA256错误，请检查或移走该临时文件后重试')
                part.replace(archive)
                extract(archive, root)
                (root / (name + '.extracted.sha256')).write_text(digest + '\n')
                continue
            request = Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
            with urlopen(request, timeout=60) as response:
                resumed = offset > 0 and response.status == 206
                if resumed and not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                    raise ValueError('服务器断点范围不符')
                written = offset if resumed else 0
                with part.open('ab' if resumed else 'wb') as output:
                    previous = written // (64 * 1024 * 1024)
                    for block in iter(lambda: response.read(4 * 1024 * 1024), b''):
                        output.write(block); written += len(block)
                        current = written // (64 * 1024 * 1024)
                        if current != previous:
                            print(f'  {written / size:.1%}', flush=True); previous = current
            if part.stat().st_size != size or checksum(part) != digest:
                raise ValueError(f'{part}长度/SHA256不符；保留临时文件供检查，不进行解压')
            part.replace(archive)
        marker = root / (name + '.extracted.sha256')
        if not marker.is_file() or marker.read_text().strip() != digest:
            extract(archive, root); marker.write_text(digest + '\n')
        print('已校验并解压：', name, flush=True)
    if not args.run:
        print('未下载；完整下载约1.83GB，需要较长时间，由用户加--run执行。')


if __name__ == '__main__':
    main()
