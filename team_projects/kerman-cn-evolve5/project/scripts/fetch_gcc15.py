import hashlib,json,time,urllib.request,zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]/'work/toolchains';root.mkdir(exist_ok=True)
name='xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64.zip'
url='https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/'+name
checksum=urllib.request.urlopen(url+'.sha',timeout=60).read().decode().split()[0].lower()
archive=root/name
if not archive.exists():
    with urllib.request.urlopen(url,timeout=120) as response,archive.with_suffix('.partial').open('wb') as out:
        total=0;last=time.monotonic()
        while chunk:=response.read(1024*1024):
            out.write(chunk);total+=len(chunk)
            if time.monotonic()-last>20:print(f'DOWNLOAD {total//1048576} MiB',flush=True);last=time.monotonic()
    archive.with_suffix('.partial').rename(archive)
actual=hashlib.sha256(archive.read_bytes()).hexdigest()
assert actual==checksum,('Official checksum mismatch',actual,checksum)
target=root/'gcc15';target.mkdir(exist_ok=True)
with zipfile.ZipFile(archive) as z:
    for entry in z.infolist():
        assert (target/entry.filename).resolve().is_relative_to(target.resolve())
    z.extractall(target)
record=dict(source=url,official_checksum_url=url+'.sha',sha256=actual,bytes=archive.stat().st_size,installed_under=str(target),system_path_changed=False)
(root/'gcc15_install.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
print('GCC15_VERIFIED_EXTRACTED',flush=True)
