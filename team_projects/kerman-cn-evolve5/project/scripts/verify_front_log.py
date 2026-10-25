"""Read-only FRONT1 one-boot/one-pair log validation, including actual config."""
import argparse,hashlib,json,re
from pathlib import Path
from regress import PROJECT
from verify_m_log import verify as verify_base

def expected_front(prepared):
    f=prepared['frontend'];bits=prepared['branch_prediction']['index_bits']
    raw=0xf1000000|(bits<<20)|(f['fetch_depth']<<16)|(f['ras_depth']<<8)|(f['pht_bits']<<4)|(int(f.get('fetch_bypass',False))<<2)|(int(f['load_forward'])<<1)|int(f['gshare_enabled'])
    return [raw,int(f['gshare_enabled']),f['pht_bits'],f['ras_depth'],f['fetch_depth'],int(f['load_forward'])]
def verify(text,prepared,origin='unspecified',iterations=2048):
    result=verify_base(text,prepared,'native',origin,iterations)
    lines=[x.strip() for x in text.splitlines()]
    headers=[x for x in lines if x.startswith('FRONT_CFG=')]
    assert len(headers)==1,'Require exactly one FRONT_CFG'
    match=re.fullmatch(r'FRONT_CFG=([0-9a-fA-F]{8}) GSHARE=(\d+) PHT_BITS=(\d+) RAS=(\d+) FETCH=(\d+) LOAD_FWD=(\d+)',headers[0])
    assert match,'Malformed front-end configuration'
    actual=[int(match[1],16)]+[int(match[i]) for i in range(2,7)]
    assert actual==expected_front(prepared),'Wrong front-end configuration (including bypass bit 2)'
    assert lines.index(headers[0])<next(i for i,x in enumerate(lines) if x.startswith('CM_BEGIN ')),'Configuration arrived after benchmark began'
    result['frontend']=prepared['frontend'];result['front_config']=f'{actual[0]:08x}'
    return result
def main():
    p=argparse.ArgumentParser();p.add_argument('log',type=Path)
    p.add_argument('--config',choices=('baseline','lean32','combo256'),required=True)
    p.add_argument('--origin',choices=('board','simulation','unspecified'),default='unspecified')
    p.add_argument('--output',type=Path);a=p.parse_args()
    release=json.loads((PROJECT/'release.json').read_text())
    build=json.loads((PROJECT/release['variants'][a.config]['pds_report']).read_text())
    result=verify(a.log.read_text(encoding='utf-8-sig'),build['prepared'],a.origin)
    result['config']=a.config;result['log_sha256']=hashlib.sha256(a.log.read_bytes()).hexdigest()
    target=a.output or a.log.with_suffix('.front1.json');target.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print('FRONT1_LOG_PASS '+str(target))
if __name__=='__main__':main()
