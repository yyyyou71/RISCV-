"""Only the newly generated Multiply-Adder boundary, using the vendor primitive."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
from xml.etree import ElementTree as ET
from prepare_ips import ROOT,DEFAULT_PDS


def main():
    if os.name=='nt' and not os.environ.get('MGLS_LICENSE_FILE'):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
            os.environ['MGLS_LICENSE_FILE']=winreg.QueryValueEx(key,'MGLS_LICENSE_FILE')[0]
    out=ROOT/'build/ai-first-layer/vendor';out.mkdir(parents=True,exist_ok=True)
    simulator=Path('C:/diskE/modelsim/win64')
    def run(name,args):
        r=subprocess.run(list(map(str,args)),cwd=out,capture_output=True,text=True,errors='replace',timeout=60)
        text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text,encoding='utf-8')
        if r.returncode or '** Error' in text or '** Fatal' in text:raise RuntimeError(text[-5000:])
        return text
    if not (out/'work').exists():run('vlib',[simulator/'vlib.exe','work'])
    if not (out/'modelsim.ini').exists():run('ini',[simulator/'vmap.exe','-c'])
    run('map',[simulator/'vmap.exe','work',out/'work'])
    ip=ROOT/'ipcore/pango_ai_multadd'
    sources=[ROOT/'rtl/multiply_adder_w8a16.v',ROOT/'sim/ai/TB_ai_vendor_multadd.v']
    sources += [ip/p.attrib['pathname'] for p in ET.parse(ip/'pango_ai_multadd.idf').findall('file_list/source/file')]
    vendor=DEFAULT_PDS/'arch/vendor/pango/verilog/simulation'
    sources += [vendor/'GTP_APM_E2.v',vendor/'GTP_GRS.v']
    run('compile',[simulator/'vlog.exe','-sv',*sources])
    result=run('run',[simulator/'vsim.exe','-c','-quiet','-onfinish','exit','work.TB_ai_vendor_multadd',
                      '-do','onerror {quit -code 1}; run -all; quit -code 1'])
    line=next((s for s in result.splitlines() if 'PASS vendor AI' in s),None)
    if not line:raise RuntimeError(result[-5000:])
    report=dict(passed=True,scope='new vendor Multiply-Adder only',summary=line,full_ai_simulation=False,
                sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sources if p.is_relative_to(ROOT)})
    (ROOT/'reports/preprocess/first_layer_vendor_ip.json').write_text(json.dumps(report,indent=2)+'\n')
    print(line)


if __name__=='__main__':main()
