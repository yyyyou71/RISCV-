"""Audit this build, keeping CPU timing acceptance separate from other clocks."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time
from audit_video_build import timing_sections, timing_passes

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--watch', action='store_true')
    parser.add_argument('--run-dir',type=Path,default=Path('build/interactive-accel/board-run'))
    parser.add_argument('--output',type=Path,default=Path('reports/video_integration/interactive_accel_implementation.json'))
    args = parser.parse_args()
    run = ROOT / args.run_dir
    if args.watch:
        while json.loads((run / 'state.json').read_text())['phase'] == 'running':
            time.sleep(10)
    state = json.loads((run / 'state.json').read_text())
    sources = json.loads((run / 'source_hashes.json').read_text())
    unchanged = all((ROOT / p).exists() and hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h
                    for p, h in sources.items())
    latest = max((ROOT / p).stat().st_mtime for p in sources)
    report_path = ROOT / 'report_timing/acore_dual_top.rtr'
    fresh = report_path.exists() and report_path.stat().st_mtime >= latest
    sections = timing_sections(report_path) if fresh else {}
    cpu = {name: [r for r in rows if r['path'].split()[0] == 'sys_clk' and
                  ('Pulse' in name or r['path'].split()[1] == 'sys_clk')]
           for name, rows in sections.items()}
    cpu = {name: rows for name, rows in cpu.items() if rows}
    required = {f'{kind} Summary({corner} Corner)' for kind in ['Setup', 'Hold']
                for corner in ['Slow', 'Fast']}
    cpu_pass = fresh and required.issubset(cpu) and all(
        r['slack_ns'] >= 0 and r['failing_endpoints'] == 0 for rows in cpu.values() for r in rows)
    violations = {name: [r for r in rows if r['slack_ns'] < 0 or r['failing_endpoints']]
                  for name, rows in sections.items()}
    violations = {name: rows for name, rows in violations.items() if rows}
    # Conservative review boundary, not a relaxation of the design constraints.
    severe = {name: [r for r in rows if r['slack_ns'] < (-0.1 if 'Hold' in name else -0.5)]
              for name, rows in violations.items()}
    severe = {name: rows for name, rows in severe.items() if rows}
    net = ROOT / 'synthesize/acore_dual_top_syn.vm'
    text = net.read_text(errors='replace') if net.exists() else ''
    module = re.search(r'\bmodule ddr_cpu_window\b(.*?)\bendmodule\b', text, re.S)
    window = module[1] if module else ''
    mapping = {'cpu_payload_ff': len(re.findall(r'GTP_DFF_E /\* \\cpu_buf\[', window)),
               'cpu_payload_shadow_ram': bool(re.search(r'GTP_RAM\w+ /\* cpu_buf_', window))}
    bit = ROOT / 'generate_bitstream/acore_dual_top.sbit'
    bit_fresh = bit.exists() and bit.stat().st_mtime >= latest
    result = dict(build=state, sources_unchanged=unchanged, final_report_fresh=fresh,
                  cpu_internal_timing_passed=cpu_pass, cpu_timing=cpu,
                  all_timing_passed=timing_passes(sections), remaining_violations=violations,
                  violations_requiring_further_work=severe,
                  full_design_window_mapping=mapping, bitstream_generated=bit_fresh,
                  bitstream_sha256=hashlib.sha256(bit.read_bytes()).hexdigest() if bit_fresh else None,
                  board_tested=False, full_network_speed_measured=False)
    result['delivery_ready'] = bool(state.get('returncode') == 0 and unchanged and cpu_pass and
                                   bit_fresh and mapping['cpu_payload_ff'] == 2048 and
                                   not mapping['cpu_payload_shadow_ram'] and not severe)
    (ROOT / args.output).write_text(
        json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)
    return 0 if result['delivery_ready'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
