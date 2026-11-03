"""下载WIDER训练/验证图像与标注，支持断点续传及固定SHA256；只有--run才下载。"""
import argparse
import hashlib
from http.client import IncompleteRead
from pathlib import Path
import ssl
import stat
import time
from urllib.error import HTTPError, URLError
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


def download(url, archive, size, digest, attempts=5):
    """连接或传输临时失败时重连；仅将长度和哈希都正确的文件转正。"""
    part = archive.with_name(archive.name + '.part')
    for attempt in range(1, attempts + 1):
        offset = part.stat().st_size if part.exists() else 0
        if offset > size:
            raise ValueError(f'{part}比预期文件大，请检查该临时文件')
        if offset == size:
            break
        request = Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
        print(f'  连接 {attempt}/{attempts}；已保留 {offset / (1024 * 1024):.1f} MiB', flush=True)
        failure = None
        try:
            with urlopen(request, timeout=60) as response:
                resumed = offset > 0 and response.status == 206
                if response.status == 206 and not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                    raise ValueError('服务器断点范围不符')
                # 服务器不支持Range时覆盖临时文件，避免把完整响应追加成重复数据。
                written = offset if resumed else 0
                print(f'  已连接：{written / size:.1%}，单次网络操作超时60秒', flush=True)
                with part.open('ab' if resumed else 'wb') as output:
                    previous_time = time.monotonic()
                    previous_written = written
                    for block in iter(lambda: response.read(1024 * 1024), b''):
                        output.write(block); written += len(block)
                        now = time.monotonic()
                        # 按时间显示进度，慢速网络不必等到64MiB才有输出。
                        if now - previous_time >= 2 or written >= size:
                            speed = (written - previous_written) / max(now - previous_time, 1e-9) / (1024 * 1024)
                            print(f'  {written / size:.1%}（{written / (1024 * 1024):.1f}/{size / (1024 * 1024):.1f} MiB，{speed:.2f} MiB/s）', flush=True)
                            previous_time, previous_written = now, written
            if written < size:
                raise ConnectionError('连接提前结束，已保留收到的数据')
        except HTTPError as exc:
            # 只重试临时HTTP错误；地址、权限或断点错误需直接报告。
            exc.close()
            if exc.code not in {408, 429, 500, 502, 503, 504}:
                raise
            failure = exc
        except (URLError, TimeoutError, ConnectionError, IncompleteRead, ssl.SSLEOFError) as exc:
            # 证书验证失败不能靠重试或跳过验证来掩盖。
            if isinstance(getattr(exc, 'reason', exc), ssl.SSLCertVerificationError):
                raise
            failure = exc
        if failure is None:
            break
        if attempt == attempts:
            raise RuntimeError(f'{archive.name}连接/传输失败{attempts}次；已保留临时文件，可稍后重跑同一命令') from failure
        delay = min(2 ** (attempt - 1), 8)
        detail = f'HTTP {failure.code}' if isinstance(failure, HTTPError) else str(getattr(failure, 'reason', failure))
        print(f'  临时网络错误：{detail}；{delay}秒后重新连接并尝试续传', flush=True)
        time.sleep(delay)
    print('  正在校验长度和SHA256', flush=True)
    if part.stat().st_size != size or checksum(part) != digest:
        raise ValueError(f'{part}长度/SHA256不符；保留临时文件供检查，不进行解压')
    part.replace(archive)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, default=PROJECT / 'pc_ai/datasets/wider_face')
    p.add_argument('--endpoint', default='https://huggingface.co', help='可显式指定HF镜像；仍校验相同固定SHA256')
    p.add_argument('--attempts', type=int, default=5, help='每个文件最多连接尝试次数，默认5次')
    p.add_argument('--run', action='store_true')
    args = p.parse_args()
    if not args.endpoint.startswith('https://'):
        p.error('--endpoint需要HTTPS地址')
    if args.attempts < 1:
        p.error('--attempts须至少为1')
    for name, (size, digest) in FILES.items():
        url = f'{args.endpoint.rstrip("/")}/datasets/CUHK-CSE/wider_face/resolve/{REVISION}/data/{name}'
        print(name, size, 'bytes', url, flush=True)
        if not args.run:
            continue
        root = args.root.expanduser().resolve(); root.mkdir(parents=True, exist_ok=True)
        archive = root / name
        if not archive.is_file() or archive.stat().st_size != size or checksum(archive) != digest:
            download(url, archive, size, digest, attempts=args.attempts)
        marker = root / (name + '.extracted.sha256')
        if not marker.is_file() or marker.read_text().strip() != digest:
            extract(archive, root); marker.write_text(digest + '\n')
        print('已校验并解压：', name, flush=True)
    if not args.run:
        print('未下载；完整下载约1.83GB，需要较长时间，由用户加--run执行。')


if __name__ == '__main__':
    main()
