"""Register preprocessing RTL and its generated IP in the root PDS.

P2 connects these modules to CPU control, frame ownership and DDR output.
This does not enable AI or change the board's current firmware.
"""
from pathlib import Path
from xml.etree import ElementTree as ET
from export_project import ROOT, group_end, complete_source_metadata


def main():
    p=ROOT/'rv32I.pds';text=p.read_text(encoding='utf-8')
    def append(widget,body):
        nonlocal text
        start=text.index('(_widget '+widget);start=text.index('(_input',start)
        end=group_end(text,start)
        text=text[:end]+'\n'+body+'            '+text[end:]
    body=''
    for source in sorted((ROOT/'rtl/video/preprocess').glob('*.v')):
        rel=source.relative_to(ROOT).as_posix()
        if '(_file "'+rel+'"' not in text:
            body+='                (_file "'+rel+'" (_format verilog))\n'
    if body:append('wgt_my_design_src',body)
    ip=ROOT/'ipcore/pango_pool_sum_ram/pango_pool_sum_ram.idf';rel=ip.relative_to(ROOT).as_posix()
    if '(_ip "'+rel+'"' not in text:
        body='                (_ip "'+rel+'"\n'
        for f in ET.parse(ip).findall('file_list/source/file'):
            path=(ip.parent/f.attrib['pathname']).relative_to(ROOT).as_posix()
            body+='                    (_ip_source_item "'+path+'")\n'
        append('wgt_my_ips_src',body+'                )\n')
    text,added=complete_source_metadata(text,ROOT)
    p.write_text(text,encoding='utf-8',newline='\n')
    print('Preprocessing sources/IP registered; firmware images unchanged.',added)


if __name__=='__main__':main()
