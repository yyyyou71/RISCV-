"""Audit current board artifacts; distinguish bitstream generation from timing closure."""
from pathlib import Path
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parents[1]


def timing_sections(path):
    sections={};section=None
    for line in path.read_text(errors='replace').splitlines():
        if 'Summary(' in line:
            section=line.strip().rstrip(':')
        elif line.startswith('===='):
            section=None
        row=re.search(r'(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$',line)
        if section and row:
            sections.setdefault(section,[]).append(dict(path=line.strip(),slack_ns=float(row[1]),
                total_slack_ns=float(row[2]),failing_endpoints=int(row[3]),endpoints=int(row[4])))
    return sections


def timing_passes(sections):
    required={f'{kind} Summary({corner} Corner)' for kind in ('Setup','Hold') for corner in ('Slow','Fast')}
    return required.issubset(sections) and all(r['slack_ns']>=0 and r['failing_endpoints']==0
                                              for rows in sections.values() for r in rows)


def main():
    pds=(ROOT/'rv32I.pds').read_text(encoding='utf-8')
    paths=[]
    for name in re.findall(r'\((?:_file|_ip|_ip_source_item) "([^"]+)"',pds):
        p=(ROOT/name).resolve()
        if p.is_relative_to(ROOT) and p.relative_to(ROOT).parts[0] in ('rtl','board','ipcore'):
            paths.append(p)
    paths=sorted(set(paths))
    if not paths:raise RuntimeError('No hardware sources found in root PDS')
    latest=max(p.stat().st_mtime for p in paths)
    files={name:ROOT/name for name in (
        'generate_bitstream/acore_dual_top.sbit','place_route/acore_dual_top.prr',
        'place_route/acore_dual_top.rtr','place_route/acore_dual_top_timing_summary_after_hold_fix.txt')}
    fresh={name:p.is_file() and p.stat().st_mtime>=latest for name,p in files.items()}
    summary=files['place_route/acore_dual_top_timing_summary_after_hold_fix.txt']
    sections=timing_sections(summary) if fresh[summary.relative_to(ROOT).as_posix()] else {}
    final=files['place_route/acore_dual_top.rtr']
    final_sections=timing_sections(final) if fresh[final.relative_to(ROOT).as_posix()] else {}
    timing_passed=timing_passes(sections) and timing_passes(final_sections)
    log=ROOT/'build/video-platform/pds_console.log'
    text=log.read_text(errors='replace') if log.exists() else ''
    errors=re.findall(r'^E:.*$',text,re.M)
    matches=re.findall(r"The pattern '([^']+)'[^\n]*match (\d+) objects",text)
    scoped=[dict(pattern=p,count=int(n)) for p,n in matches if any(t in p for t in
            ('req_meta','ack_meta','init_meta','ready_meta','fault_meta','stream_meta','sclPipe','sdaPipe','u_video_monitor'))]
    resources={}
    resource_text=files['place_route/acore_dual_top.prr'].read_text(errors='replace') if fresh['place_route/acore_dual_top.prr'] else ''
    header=re.search(r'^\| Module Inst Name\s*\|(.+)$',resource_text,re.M)
    total=re.search(r'^\| acore_dual_top\s*\|(.+)$',resource_text,re.M)
    if header and total:
        labels=[s.strip() for s in header[1].split('|') if s.strip()]
        values=[float(s.strip()) for s in total[1].split('|') if s.strip()]
        resources=dict(zip(labels,values))
    report=dict(passed=all(fresh.values()) and timing_passed and not errors,
        bitstream_generated=fresh['generate_bitstream/acore_dual_top.sbit'],
        timing_summary_passed=timing_passed,scope='internally constrained clocks and CDC budgets; HDMI external input delay budgets are not specified',
        artifacts_fresh=fresh,errors=errors,scoped_constraint_matches=scoped,timing_sections=sections,
        final_timing_sections=final_sections,final_timing_passed=timing_passes(final_sections),
        resources=resources,
        sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
        artifacts={name:dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                   for name,p in files.items() if p.is_file()},
        hardware_tested=False,preprocessing_connected=False,ai_enabled=False)
    dest=ROOT/'reports/video_integration/ddr_timing_fix.json'
    dest.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('DDR implementation audit:', 'PASS' if report['passed'] else 'FAIL')
    print('Fresh artifacts:',fresh,'Timing summary passed:',timing_passed)
    if not report['passed']:raise SystemExit(1)


if __name__=='__main__':main()
