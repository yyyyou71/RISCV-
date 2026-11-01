"""Port-level lint of the physical M2 top; vendor PHY/IP logic is a black box.

Extract port declarations from the actual imported wrappers. This does not
simulate vendor IP, run PDS, or prove timing/physical implementation.
"""
from pathlib import Path
from collections import Counter
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def ports(path, name):
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(), flags=re.S)
    start = re.search(r'\bmodule\s+' + name + r'\b', source).start()
    end = source.index(');', start) + 2
    header = source[start:end]
    if not re.search(r'\binput\b', header):
        header += '\n' + '\n'.join(re.findall(
            r'(?m)^\s*(?:localparam|parameter|input|output|inout)\b[^;]*;', source[end:]))
    return header + '\nendmodule\n'


def main():
    out = ROOT / 'build/video-integration/lint'
    out.mkdir(parents=True, exist_ok=True)
    vendor = [ROOT / 'ipcore' / name / (name + '.v') for name in
              ['pcie_test', 'ddr3', 'PLL_CLK', 'fifo_2_ddr', 'ddr_2_fifo']]
    vendor.append(ROOT / 'rtl/pcie/dma/ips2l_pcie_dma_ram/ips2l_pcie_dma_ram.v')
    stubs = out / 'vendor_ports.v'
    stubs.write_text('\n'.join(ports(p, p.stem) for p in vendor))
    excluded = {'memory_core.v', 'ROM_core.v', 'multiplier_core.v', 'acore_fetch_memory.v',
                'multiply_adder.v', 'multiply_adder_w8a16.v', 'video_async_fifo.v', 'MuxKeyInternal.v'}
    sources = [p for p in sorted((ROOT / 'rtl').glob('*.v')) if p.name not in excluded]
    for directory, pattern in [('rtl/video', '**/*.v'), ('rtl/rk_fspi', '*.v'),
                               ('board', '*.v'), ('sim/models', '*.v'),
                               ('ipcore/pcie_test/rtl/hsst_pipe', '*.v')]:
        sources += sorted((ROOT / directory).glob(pattern))
    sources += [p for p in sorted((ROOT / 'rtl/pcie/dma').rglob('*.v'))
                if 'ips2l_pcie_dma_ram' not in p.parts]
    cmd = ['verilator', '--lint-only', '--timing', '-Wno-fatal', '-Wno-TIMESCALEMOD',
           '--top-module', 'acore_dual_top',
           '-DPROG_FILE="firmware/acore_dual_rom.hex"',
           '-DDATA_FILE="firmware/acore_dual_ram_bytes.hex"', str(stubs), *map(str, sources)]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
    log = result.stdout + result.stderr
    (out / 'platform_lint.log').write_text(log)
    warnings = Counter(re.findall(r'%Warning-([A-Z0-9_]+):', log))
    critical = {k: n for k, n in warnings.items() if k in
                {'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT', 'SELRANGE', 'IMPLICIT', 'PINNOTFOUND'}}
    report = dict(passed=result.returncode == 0 and not critical,
                  scope='structural ports only; vendor IP is black-boxed, ENABLE_AI=0',
                  warnings=dict(warnings), critical=critical,
                  pds_run=False, hardware_tested=False,
                  sources={p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sources + vendor + [Path(__file__).resolve()]})
    dest = ROOT / 'reports/video_integration/structural.json'
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(report, indent=2) + '\n')
    print('M2 port-level lint:', 'PASS' if report['passed'] else 'FAIL', dict(warnings))
    if not report['passed']:
        print(log[-6000:])
        raise SystemExit(1)


if __name__ == '__main__':
    main()
