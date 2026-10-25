"""Strict DUAL1 one-boot performance/validation acceptance (no serial access)."""
import argparse,hashlib,json,re
from pathlib import Path
from regress import PROJECT
from verify_front_log import verify as verify_front

def check_dual_boot(text,prepared):
    lines=[x.strip() for x in text.splitlines()]
    assert prepared['firmware']['build_id']=='EVOLVE1_BOARD','Unsupported release firmware'
    assert lines.count('BUILD='+prepared['firmware']['build_id'])==1,'Wrong EVOLVE firmware build'
    for prefix in ('BUILD=','BP_ENABLE=','HW_ID=','CLK='):
        assert sum(x.startswith(prefix) for x in lines)==1,'Missing/duplicate identity: '+prefix
    cfg=prepared['issue'];dual=int(cfg['dual_enabled']);wide=int(cfg['wide_fetch'])
    headers=[x for x in lines if x.startswith('ISSUE_CFG=')]
    expected=f'ISSUE_CFG={0xd1000000|dual|(wide<<1):08x} ISSUE_WIDTH={1+dual} FETCH_WORDS={1+wide}'
    assert headers==[expected],'Missing, duplicate or wrong issue configuration'
    checks=[x for x in lines if x.startswith('DUAL_CHECK')]
    assert len(checks)==1,'Require exactly one dual-issue boot check'
    match=re.fullmatch(r'DUAL_CHECK PASS iterations=(\d+) cycles=(\d+) instret=(\d+) pairs=(\d+)',checks[0])
    assert match,'Malformed or failed DUAL_CHECK'
    iterations,cycles,instret,pairs=map(int,match.groups())
    assert iterations==1024 and instret==34818 and cycles>0,'Invalid microbenchmark instruction window'
    assert 0<=pairs<=instret//2,'Impossible pair count'
    assert pairs>0 if dual else pairs==0,'Pair activity does not match issue configuration'
    if dual and wide and prepared['caches']['icache_enabled']:
        assert cycles<instret,'Independent ALU microbenchmark did not exceed IPC 1'
    first=next(i for i,x in enumerate(lines) if x.startswith('CM_BEGIN '))
    assert lines.index(headers[0])<lines.index(checks[0])<lines.index('PORT_CHECK PASS')<first,'Misordered boot checks'
    return dict(config=f'{0xd1000000|dual|(wide<<1):08x}',issue=cfg,
                microbenchmark=dict(iterations=iterations,cycles=cycles,instret=instret,pairs=pairs,ipc=instret/cycles))

def verify(text,prepared,origin='unspecified',iterations=2048):
    result=verify_front(text,prepared,origin,iterations)
    result.update(check_dual_boot(text,prepared))
    result['stage']='EVOLVE5'
    return result

def main():
    p=argparse.ArgumentParser();p.add_argument('log',type=Path)
    p.add_argument('--config',required=True)
    p.add_argument('--origin',choices=('board','simulation','unspecified'),default='unspecified')
    p.add_argument('--iterations',type=int,default=2048);p.add_argument('--output',type=Path);a=p.parse_args()
    release=json.loads((PROJECT/'release.json').read_text())
    assert release['stage']=='EVOLVE5' and a.config in release['variants'],'Unpublished configuration'
    build=json.loads((PROJECT/release['variants'][a.config]['pds_report']).read_text())
    assert build['status']=='passed'
    result=verify(a.log.read_text(encoding='utf-8-sig'),build['prepared'],a.origin,a.iterations)
    result['config_name']=a.config;result['log_sha256']=hashlib.sha256(a.log.read_bytes()).hexdigest()
    result['expected_bitstream_sha256']=build['bitstream_sha256']
    result['bitstream_identity_note']='Expected file identity; UART alone cannot attest which bitstream was programmed.'
    target=a.output or a.log.with_suffix('.evolve5.json');target.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print('EVOLVE5_LOG_PASS '+str(target))
if __name__=='__main__':main()
