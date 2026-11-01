"""Read current PDS reports; never treat a generated bitstream as timing closure."""
import hashlib
import json
from pathlib import Path
import re
from audit_video_build import timing_sections, timing_passes

ROOT=Path(__file__).resolve().parents[1]


def main():
    project=(ROOT/'rv32I.pds').read_text(encoding='utf-8')
    sources=sorted({ROOT/name for name in re.findall(r'\((?:_file|_ip|_ip_source_item) "([^"]+)"',project)
                    if name.split('/')[0] in ('rtl','board','ipcore')})
    latest=max(p.stat().st_mtime for p in sources)
    artifacts={name:ROOT/name for name in ['synthesize/acore_dual_top.snr','place_route/acore_dual_top.prr',
        'place_route/acore_dual_top.rtr','report_timing/acore_dual_top.rtr',
        'generate_bitstream/acore_dual_top.sbit']}
    fresh={name:p.exists() and p.stat().st_mtime>=latest for name,p in artifacts.items()}
    sections={}
    for name in ['synthesize/acore_dual_top.snr','place_route/acore_dual_top.rtr','report_timing/acore_dual_top.rtr']:
        sections[name]=timing_sections(artifacts[name]) if fresh[name] else {}
    resources={}
    snr=artifacts['synthesize/acore_dual_top.snr'].read_text(errors='replace') if fresh['synthesize/acore_dual_top.snr'] else ''
    for key,pattern,total in [('LUT',r'Total LUTs:\s*([\d.]+)',66600),
        ('FF',r'Total Registers:\s*([\d.]+)',133200),('APM',r'Total APMs =\s*([\d.]+)',240),
        ('DRM36K_equivalent',r'Total DRM =\s*([\d.]+)',155)]:
        m=re.search(pattern,snr)
        if m:resources[key]=dict(used=float(m[1]),capacity=total,percent=round(float(m[1])*100/total,2))
    routed={}
    if fresh['place_route/acore_dual_top.prr']:
        text=artifacts['place_route/acore_dual_top.prr'].read_text(errors='replace')
        header=re.search(r'^\| Module Inst Name\s*\|(.+)$',text,re.M)
        row=re.search(r'^\| acore_dual_top\s*\|(.+)$',text,re.M)
        if header and row:
            routed=dict(zip([s.strip() for s in header[1].split('|') if s.strip()],
                            [float(s.strip()) for s in row[1].split('|') if s.strip()]))
    timing_ok=all(timing_passes(sections[name]) for name in
                  ['place_route/acore_dual_top.rtr','report_timing/acore_dual_top.rtr'])
    routed_percentages={key:dict(used=routed[key],capacity=capacity,
                                percent=round(routed[key]*100/capacity,2))
                        for key,capacity in [('LUT',66600),('FF',133200),('APM',240),('DRM',155)] if key in routed}
    expected=ROOT/'build/timing-closure/final_source_hashes.json'
    snapshot=json.loads(expected.read_text()) if expected.exists() else {}
    unchanged=bool(snapshot) and all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==value for name,value in snapshot.items())
    log=ROOT/'build/timing-closure/final_flow.log'
    errors=re.findall(r'^E:.*',log.read_text(errors='replace'),re.M) if log.exists() else []
    report=dict(base_commit='c39d798',part='PG2L100H FBG484 -6',groute_seed=3,
        build_sources_unchanged=unchanged,artifacts_fresh=fresh,
        synthesis_resources=resources,routed_resource_columns=routed,routed_resources=routed_percentages,
        timing_sections=sections,internally_constrained_timing_passed=timing_ok,
        bitstream_generated=fresh['generate_bitstream/acore_dual_top.sbit'],errors=errors,
        passed=all(fresh.values()) and timing_ok and unchanged and not errors,
        timing_scope='Internal clocks and specified CDC/SPI budgets. HDMI external input delays remain unspecified.',
        fpga_board_verified=False,full_network_run=False,coremark_run=False,
        sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        artifacts={name:dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for name,p in artifacts.items() if p.exists()})
    checks=ROOT/'reports/video_integration/timing_unit_checks.json'
    report['targeted_checks']=json.loads(checks.read_text()) if checks.exists() else None
    destination=ROOT/'reports/video_integration/timing_closure_p5.json'
    destination.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:report[k] for k in ['passed','build_sources_unchanged','artifacts_fresh','internally_constrained_timing_passed','synthesis_resources']},indent=2))
    raise SystemExit(0 if report['passed'] else 1)


if __name__=='__main__':main()
