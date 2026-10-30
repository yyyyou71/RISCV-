"""Check the generated accumulator RAM with ModelSim and Pango's real primitive."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from xml.etree import ElementTree as ET
from prepare_ips import DEFAULT_PDS,ROOT


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pds-root',type=Path,default=DEFAULT_PDS)
    parser.add_argument('--modelsim',type=Path,default=Path(r'C:\diskE\modelsim\win64'))
    args=parser.parse_args()
    if os.name=='nt' and not os.environ.get('MGLS_LICENSE_FILE'):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
            os.environ['MGLS_LICENSE_FILE']=winreg.QueryValueEx(key,'MGLS_LICENSE_FILE')[0]
    out=ROOT/'build/preprocess/vendor';out.mkdir(parents=True,exist_ok=True)
    def run(name,command):
        r=subprocess.run(list(map(str,command)),cwd=out,capture_output=True,text=True,errors='replace',timeout=90)
        text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text,encoding='utf-8')
        if r.returncode or '** Error' in text or '** Fatal' in text:raise RuntimeError(text[-6000:])
        return text
    if not (out/'work').exists():run('vlib',[args.modelsim/'vlib.exe','work'])
    if not (out/'modelsim.ini').exists():run('configuration',[args.modelsim/'vmap.exe','-c'])
    run('mapping',[args.modelsim/'vmap.exe','work',out/'work'])
    ip=ROOT/'ipcore/pango_pool_sum_ram'
    sources=[ROOT/'rtl/video/preprocess/pool_sum_ram.v',ROOT/'sim/video/TB_pool_sum_ram.v']
    sources += [ip/f.attrib['pathname'] for f in ET.parse(ip/'pango_pool_sum_ram.idf').findall('file_list/source/file')]
    vendor=args.pds_root/'arch/vendor/pango/verilog/simulation'
    sources += [vendor/'GTP_DRM36K_E1.v',vendor/'GTP_GRS.v']
    run('compile',[args.modelsim/'vlog.exe','-sv','+define+VENDOR_RAM',*sources])
    text=run('run',[args.modelsim/'vsim.exe','-c','-quiet','-onfinish','exit',
                    '-l','transcript.log','work.TB_pool_sum_ram','-do',
                    'onerror {quit -code 1}; run -all; quit -code 1'])
    if 'PASS pool RAM IP:' not in text:raise RuntimeError(text[-5000:])
    summary=next(s for s in text.splitlines() if 'PASS pool RAM IP:' in s)
    report=dict(passed=True,simulator='ModelSim with generated vendor RAM + GTP_DRM36K_E1',
                summary=summary,sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sources if p.is_relative_to(ROOT)})
    dest=ROOT/'reports/preprocess/vendor_ram.json';dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(report,indent=2)+'\n')
    print(summary)


if __name__=='__main__':main()
