"""Select and regenerate only the existing Acore ROM/RAM initialization.

Preserves every IP parameter except INIT_FILE. --verify-only decodes the
generated DRM INIT constants and checks all words without running simulation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
from prepare_ips import DEFAULT_PDS,ROOT


def params(path):
    return {p.findtext('name'):p.findtext('value') for p in ET.parse(path).findall('param_list/param')}


def verify_embedded(instance,image):
    text=(ROOT/'ipcore'/instance/'rtl'/(instance+'_init_param.v')).read_text()
    constants={(int(index,16),int(bank),int(lane)):int(value,16)
               for index,bank,lane,value in re.findall(
                   r"localparam INIT_([0-9A-Fa-f]+)_(\d+)_(\d+)\s*=\s*288'h([0-9a-fA-F]+)",text)}
    expected=[int(word,16) for word in image.read_text().split()]
    # Current 36K/byte-enable configuration splits each 32-bit word into two
    # 18-bit DRM lanes, with zero parity at bits 8 and 17 and 2048 rows per bank.
    for address,word in enumerate(expected):
        actual=0
        for lane in range(2):
            physical=(constants[(address%2048//16,address//2048,lane)]>>(address%16*18))&0x3ffff
            if physical&0x20100:raise RuntimeError('Unexpected nonzero DRM parity bits')
            actual|=((physical&255)|(((physical>>9)&255)<<8))<<(lane*16)
        if actual!=word:raise RuntimeError(f'{instance} embedded word {address}: {actual:08x} != {word:08x}')
    return len(expected)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image-dir',type=Path,required=True)
    parser.add_argument('--pds-root',type=Path,default=DEFAULT_PDS)
    parser.add_argument('--verify-only',action='store_true')
    args=parser.parse_args()
    images=args.image_dir.resolve();manifest=json.loads((images/'manifest.json').read_text())
    if manifest['core']!='acore_dual':raise ValueError('Acore dual firmware manifest required')
    for name,expected in manifest['sources'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=expected:
            raise ValueError('Firmware source changed; rebuild first: '+name)
    if os.name=='nt' and not os.environ.get('PANGO_LICENSE_FILE'):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
            os.environ['PANGO_LICENSE_FILE']=winreg.QueryValueEx(key,'PANGO_LICENSE_FILE')[0]
    out=ROOT/'build/firmware_selection';out.mkdir(parents=True,exist_ok=True)
    results=[]
    for instance,kind,size in [('pango_acore_fetch','rom',8192),('pango_acore_ram','ram',16384)]:
        image=images/('acore_dual_'+kind+'.hex');image_hash=hashlib.sha256(image.read_bytes()).hexdigest()
        if image_hash!=manifest[kind+'_sha256']:raise ValueError('Firmware hash mismatch: '+str(image))
        if len(image.read_text().split())!=size:raise ValueError('Unexpected firmware image size')
        ip=ROOT/'ipcore'/instance/(instance+'.idf');before=params(ip)
        for key,value in dict(CAS_MODE='36K',A_DATA_WIDTH='32',B_DATA_WIDTH='32',
                              WR_BYTE_EN='1',BYTE_SIZE='8',POWER_OPT='0',INIT_EN='1',INIT_FORMAT='HEX').items():
            if before.get(key)!=value:raise ValueError('Unsupported existing IP configuration: '+key)
        if not args.verify_only:
            tree=ET.parse(ip)
            for item in tree.findall('param_list/param'):
                if item.findtext('name')=='INIT_FILE':item.find('value').text=image.as_posix()
            ET.indent(tree,space='    ');tree.write(ip,encoding='utf-8',xml_declaration=True)
            log=out/(instance+'_generate.log')
            with log.open('w') as stream:
                result=subprocess.run([str(args.pds_root/'bin/ip_generate.exe'),'-i',str(ip),'-disable-syn'],
                                      cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,timeout=90)
            text=log.read_text(errors='replace')
            if result.returncode or re.search(r'^E:',text,re.M):raise RuntimeError(text[-5000:])
        after=params(ip)
        if after['INIT_FILE']!=image.as_posix():raise RuntimeError('IP still selects another image')
        changed=[name for name in set(before)|set(after) if before.get(name)!=after.get(name) and name!='INIT_FILE']
        if changed:raise RuntimeError('IP generator changed unrelated parameters: '+str(changed))
        words=verify_embedded(instance,image)
        results.append(dict(instance=instance,image=image.relative_to(ROOT).as_posix(),sha256=image_hash,
                            embedded_words_verified=words,other_parameters_preserved=True))
        print(instance+': '+str(words)+' embedded words verified against '+str(image),flush=True)
    record=dict(passed=True,application=manifest['application'],ips=results,bitstream_generated=False,
                note='Rebuild root PDS before programming; existing bitstreams still contain their old images.')
    (ROOT/'reports/preprocess/selected_firmware.json').write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':main()
