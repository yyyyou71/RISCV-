"""Read-only package integrity check; run the regression scripts to re-test RTL."""
import hashlib
from pathlib import Path
project=Path(__file__).resolve().parents[1]
count=0
for line in (project/'FILE_SHA256.txt').read_text(encoding='utf-8').splitlines():
    expected,relative=line.split('  ',1); path=(project/relative).resolve()
    if not path.is_relative_to(project): raise ValueError('Manifest path outside project')
    if hashlib.sha256(path.read_bytes()).hexdigest()!=expected: raise ValueError('File mismatch: '+relative)
    count+=1
print(f'EVOLVE5_PACKAGE_HASHES_PASS files={count}')
