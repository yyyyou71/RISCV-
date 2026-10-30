"""Record P2 native synthesis evidence; this does not claim post-route closure."""
from pathlib import Path
import hashlib,json,re
from audit_video_build import timing_sections

ROOT=Path(__file__).resolve().parents[1]


def main():
    log=(ROOT/'build/preprocess/p2/synthesize.log').read_text(errors='replace')
    snr=ROOT/'synthesize/acore_dual_top.snr';text=snr.read_text(errors='replace')
    errors=re.findall(r'^E:.*$',log,re.M)
    resources={}
    header=re.search(r'^\| Module Inst Name\s*\|(.+)$',text,re.M)
    total=re.search(r'^\| acore_dual_top\s*\|(.+)$',text,re.M)
    if header and total:
        resources=dict(zip([s.strip() for s in header[1].split('|') if s.strip()],
                           [float(s.strip()) for s in total[1].split('|') if s.strip()]))
    matches={p:int(n) for p,n in re.findall(r"The pattern '([^']+)'[^\n]*match (\d+) objects",log)}
    expected=['*u_preprocess*'+name+'*' for name in
              ['req_meta','ack_meta','ready_meta','fault_meta','start_meta','cancel_meta','sof_meta','done_meta']]
    expected+=['*u_write_ctrl*overflow_meta*']
    cdc={p:matches.get(p,0) for p in expected}
    pds=(ROOT/'rv32I.pds').read_text()
    paths=sorted(set(p for p in re.findall(r'\((?:_file|_ip|_ip_source_item) "([^"]+)"',pds)
                     if p.split('/')[0] in ('board','rtl','ipcore')))
    sections=timing_sections(snr)
    report=dict(passed='Process "Synthesize" done.' in log and not errors and bool(resources) and all(n==1 for n in cdc.values()),
                stage='P2 native synthesis only',resources=resources,errors=errors,
                cdc_first_stage_matches=cdc,estimated_timing_sections=sections,
                post_route_verified=False,timing_closed=False,bitstream_generated=False,hardware_tested=False,
                sources={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in paths},
                synthesis_report_sha256=hashlib.sha256(snr.read_bytes()).hexdigest())
    dest=ROOT/'reports/preprocess/synthesis.json';dest.write_text(json.dumps(report,indent=2)+'\n')
    print('P2 native synthesis:', 'PASS' if report['passed'] else 'FAIL')
    print('Resources:',{k:resources.get(k) for k in ['LUT','FF','Distributed RAM','APM','DRM']})
    print('CDC first-stage matches:',cdc)
    if not report['passed']:raise SystemExit(1)


if __name__=='__main__':main()
