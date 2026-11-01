"""Record this HDMI build, including resource percentages and final routed timing."""
from pathlib import Path
import hashlib
import json
import re
from audit_video_build import timing_sections,timing_passes

ROOT=Path(__file__).resolve().parents[1]


def main():
    project=(ROOT/'rv32I.pds').read_text(encoding='utf-8')
    sources={ROOT/name for name in re.findall(r'\((?:_file|_ip|_ip_source_item) "([^"]+)"',project)
             if name.split('/')[0] in ('rtl','board','ipcore')}
    sources.update([ROOT/'board/pins.fdc',ROOT/'board/timing.fdc'])
    latest=max(p.stat().st_mtime for p in sources)
    artifacts={name:ROOT/name for name in ['synthesize/acore_dual_top.snr',
        'place_route/acore_dual_top.prr','place_route/acore_dual_top.rtr',
        'generate_bitstream/acore_dual_top.sbit']}
    fresh={name:p.is_file() and p.stat().st_mtime>=latest for name,p in artifacts.items()}
    timing=timing_sections(artifacts['place_route/acore_dual_top.rtr']) if fresh['place_route/acore_dual_top.rtr'] else {}
    routed={}
    if fresh['place_route/acore_dual_top.prr']:
        text=artifacts['place_route/acore_dual_top.prr'].read_text(errors='replace')
        header=re.search(r'^\| Module Inst Name\s*\|(.+)$',text,re.M)
        row=re.search(r'^\| acore_dual_top\s*\|(.+)$',text,re.M)
        if header and row:
            routed=dict(zip([x.strip() for x in header[1].split('|') if x.strip()],
                            [float(x.strip()) for x in row[1].split('|') if x.strip()]))
    resources={key:dict(used=routed[key],capacity=total,percent=round(routed[key]*100/total,2))
        for key,total in [('LUT',66600),('FF',133200),('APM',240),('DRM',155)] if key in routed}
    log=(ROOT/'build/hdmi-padding/pds_flow.log').read_text(errors='replace')
    errors=re.findall(r'^E:.*$',log,re.M)
    result=dict(bitstream_generated=fresh['generate_bitstream/acore_dual_top.sbit'],
        timing_passed=timing_passes(timing),resources=resources,timing_sections=timing,
        artifacts_fresh=fresh,errors=errors,hardware_tested=False,
        scope='HDMI 1919/1920 normalization; remaining timing violations are reported, not waived',
        timing_scope='internally constrained clocks/CDC; external HDMI input delay budget remains unspecified',
        sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)},
        artifacts={name:dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                   for name,p in artifacts.items() if fresh[name]})
    dest=ROOT/'reports/video_integration/hdmi_padding_implementation.json'
    dest.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({key:result[key] for key in ['bitstream_generated','timing_passed','resources','errors']},indent=2))


if __name__=='__main__':main()
