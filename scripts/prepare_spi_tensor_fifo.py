"""Generate the vendor 128-bit FIFO used by SPI image preprocessing."""
from pathlib import Path
import os, subprocess, xml.etree.ElementTree as ET
from prepare_ips import ROOT, DEFAULT_PDS

def main():
    name='spi_tensor_fifo'
    tree=ET.parse(ROOT/'ipcore/ddr_2_fifo/ddr_2_fifo.idf')
    root=tree.getroot();root.find('header/instance').text=name
    values={'OUTPUT_REG':'false','EMPTY_WL_EN':'true','FULL_WL_EN':'false',
            'WR_DEPTH_WIDTH':'8','RD_DEPTH_WIDTH':'8'}
    for p in root.findall('param_list/param'):
        if p.findtext('name') in values:p.find('value').text=values[p.findtext('name')]
    for key in ('pin_list','file_list'):
        node=root.find(key)
        if node is not None:node.clear()
    dest=ROOT/'ipcore'/name;dest.mkdir(exist_ok=True)
    path=dest/(name+'.idf');ET.indent(root,space='    ');tree.write(path,encoding='utf-8',xml_declaration=True)
    if not os.environ.get('PANGO_LICENSE_FILE'):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
            os.environ['PANGO_LICENSE_FILE']=winreg.QueryValueEx(key,'PANGO_LICENSE_FILE')[0]
    out=ROOT/'build/spi-image';out.mkdir(parents=True,exist_ok=True)
    with (out/'fifo_generate.log').open('w') as log:
        result=subprocess.run([str(DEFAULT_PDS/'bin/ip_generate.exe'),'-i',str(path),'-disable-syn'],
                              cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=90)
    if result.returncode:raise RuntimeError((out/'fifo_generate.log').read_text(errors='replace')[-3000:])
    print('Generated '+str(path))

if __name__=='__main__':main()
