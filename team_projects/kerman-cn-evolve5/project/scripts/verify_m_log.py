"""Strict one-boot, one performance+validation pair MEXT1 log check.

Reads a complete raw UTF-8 UART text log. Does not download or open serial ports.
Origin=board must only be used for a log actually collected from the board.
"""
import argparse,hashlib,json,re
from pathlib import Path
from regress import PROJECT
from parse_coremark import parse_text
from platform_identity import check_runs

def verify(text,prepared,variant,origin='unspecified',iterations=2048):
    fw=prepared['firmware']; lines=[line.strip() for line in text.splitlines()]
    assert lines.count('RISC-V COREMARK 1.0')==1,'Require one complete boot per file'
    assert lines.count('MISA=40001100 HW_M=1')==1,'Missing M hardware identity'
    wanted='M_CHECK PASS vectors=128 instructions=8' if variant=='native' else 'M_CHECK SKIP software-ISA control'
    assert lines.count(wanted)==1 and lines.count('PORT_CHECK PASS')==1,'Boot self-check missing'
    assert not any('FAIL' in line or 'CM_COMMAND_ERROR' in line for line in lines),'Firmware failure in log'
    assert lines[-1]=='CM_READY','Incomplete final output'
    identity=check_runs(text,prepared,fw['build_id'],fw['printed_flags'])
    assert identity['identity_checks']==[True,True] and identity['flags_checks']==[True,True],'Wrong/missing firmware identity or flags'
    assert sum(line.startswith('CM_BEGIN ') for line in lines)==2,'Require exactly one complete pair'
    parsed=parse_text(text,origin)
    assert [r['mode'] for r in parsed['runs']]==['performance','validation'],'Wrong run sequence'
    assert all(r['iterations']==iterations and r['standard_crc_valid'] and r['duration_valid'] and r['score_valid']==1 for r in parsed['runs']),'CRC/duration/iterations failed'
    return {'status':'passed','variant':variant,'origin':origin,'hardware_measurement':origin=='board',
            'contest_extension_eligibility':'unconfirmed','identity':identity,'results':parsed}

def main():
    p=argparse.ArgumentParser(); p.add_argument('log',type=Path)
    p.add_argument('--variant',choices=('native','software'),required=True)
    p.add_argument('--origin',choices=('board','simulation','unspecified'),default='unspecified')
    p.add_argument('--iterations',type=int,default=2048); p.add_argument('--output',type=Path)
    a=p.parse_args(); release=json.loads((PROJECT/'release.json').read_text())
    build=json.loads((PROJECT/release['variants'][a.variant]['pds_report']).read_text())
    result=verify(a.log.read_text(encoding='utf-8-sig'),build['prepared'],a.variant,a.origin,a.iterations)
    result['log_sha256']=hashlib.sha256(a.log.read_bytes()).hexdigest()
    target=a.output or a.log.with_suffix('.front1.json'); target.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print('MEXT1_LOG_PASS '+str(target))
if __name__=='__main__': raise SystemExit('FRONT1: use scripts/verify_front_log.py --config baseline|lean32|combo256. This module remains the shared base validator.')
