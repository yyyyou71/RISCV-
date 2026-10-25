"""Seal the audited release and verify every ZIP member against the manifest."""
import argparse,hashlib,json,zipfile
from pathlib import Path
from regress import PROJECT as P
def sha_bytes(b):return hashlib.sha256(b).hexdigest()
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,default=P.parent/'RV32IM_DUAL1_受限顺序双发射工程.zip');a=ap.parse_args()
    release=json.loads((P/'release.json').read_text());summary=json.loads((P/'reports/summary.json').read_text())
    assert release['status']=='offline_verified_board_pending' and summary['status']=='passed_offline'
    assert not a.output.exists(),'Do not overwrite a sealed ZIP; use a new output name'
    files=sorted(p for p in P.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.name!='FILE_SHA256.txt')
    entries={p.relative_to(P).as_posix():sha_bytes(p.read_bytes()) for p in files}
    manifest=P/'FILE_SHA256.txt';manifest.write_text(''.join(digest+'  '+name+'\n' for name,digest in entries.items()),encoding='utf-8')
    a.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(a.output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for p in files+[manifest]:z.write(p,(Path(P.name)/p.relative_to(P)).as_posix())
    with zipfile.ZipFile(a.output) as z:
        assert len(z.namelist())==len(files)+1
        for name,digest in entries.items():assert sha_bytes(z.read(P.name+'/'+name))==digest,name
        assert z.read(P.name+'/FILE_SHA256.txt')==manifest.read_bytes()
        assert z.testzip() is None
    result=dict(stage='DUAL1',zip=str(a.output.resolve()),zip_bytes=a.output.stat().st_size,zip_sha256=sha_bytes(a.output.read_bytes()),
                manifest_files=len(files),zip_entries=len(files)+1,zip_content_verified=True,hardware_tested=False)
    a.output.with_suffix('.sha256').write_text(result['zip_sha256']+'  '+a.output.name+'\n',encoding='utf-8')
    a.output.with_suffix('.package.json').write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps(result,indent=2,ensure_ascii=False))
if __name__=='__main__':main()
