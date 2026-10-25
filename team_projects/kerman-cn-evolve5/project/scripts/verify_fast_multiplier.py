import subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parent
for script in ('m_unit_regress.py','m_unit_mapped.py'):
    run=subprocess.run([sys.executable,str(root/script)])
    assert run.returncode==0,script
