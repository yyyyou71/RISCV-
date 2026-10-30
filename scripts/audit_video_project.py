"""Static M2 project checks. Does not invoke PDS, synthesize, or update IPs."""
from pathlib import Path
from collections import Counter
import argparse
import hashlib
import json
import re
import subprocess
from xml.etree import ElementTree as ET
from export_project import complete_source_metadata

ROOT = Path(__file__).resolve().parents[1]


def normalized(data):
    return data.replace(b'\r\n', b'\n')


def digest(data):
    return hashlib.sha256(normalized(data)).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', type=Path,
                        help='Optionally verify the original desktop source hashes as well')
    args = parser.parse_args()
    checks = {}
    pds = (ROOT / 'rv32I.pds').read_text()
    depth = 0
    quoted = False
    valid = True
    for char in pds:
        if char == '"':
            quoted = not quoted
        if not quoted:
            depth += (char == '(') - (char == ')')
            valid &= depth >= 0
    checks['pds_balanced_groups'] = bool(valid and depth == 0 and not quoted)
    files = re.findall(r'\((?:_file|_ip|_ip_source_item) "([^"]+)"', pds)
    missing = [p for p in files if not (ROOT / p).is_file()]
    duplicates = [p for p, n in Counter(files).items() if n > 1]
    checks['all_pds_paths_exist'] = not missing
    checks['no_duplicate_pds_files'] = not duplicates
    _, missing_metadata = complete_source_metadata(pds, ROOT) if not missing else ('', {'missing_files': len(missing)})
    checks['pds_required_source_metadata'] = not any(missing_metadata.values())
    checks['physical_top_selected'] = '"board/acore_dual_top.v" + "acore_dual_top:"' in pds
    checks['no_simulation_models_in_pds'] = not any(p.startswith('sim/') for p in files)
    checks['target_part'] = all(x in pds for x in
        ['(_family Logos2)', '(_device PG2L100H)', '(_package FBG484)', '(_speedgrade -6)'])
    # Hardware top uses ANSI declarations with constant numeric vector ranges.
    header = (ROOT / 'board/acore_dual_top.v').read_text().split(');', 1)[0] + ');'
    ports = set()
    for item in re.finditer(r'\b(?:input|output|inout)\s+wire\s*(\[\d+:\d+\])?\s*'
                           r'(.*?)(?=\binput\b|\boutput\b|\binout\b|\);)', header, re.S):
        width, names = item.groups()
        for name in names.strip().strip(',').split(','):
            name = name.strip()
            if width:
                hi, lo = map(int, re.findall(r'\d+', width))
                ports.update(f'{name}[{i}]' for i in range(lo, hi + 1))
            else:
                ports.add(name)
    pins = (ROOT / 'board/pins.fdc').read_text()
    locations = re.findall(r'^define_attribute \{p:([^}]+)\} \{PAP_IO_LOC\} \{([^}]+)\}', pins, re.M)
    pin_map = dict(locations)
    repeated_pins = [p for p, n in Counter(pin_map.values()).items() if n > 1]
    # PCIe serial lanes are placed by the copied hard-PHY PAP_LOC attributes.
    hsst_lanes = {f'{name}[{i}]' for name in ['rxn', 'rxp', 'txn', 'txp'] for i in range(2)}
    checks['all_general_io_pinned'] = ports - hsst_lanes == set(pin_map)
    checks['no_duplicate_pins_or_ports'] = not repeated_pins and len(locations) == len(pin_map)
    checks['ab21_hdmi_only'] = pin_map.get('r_in[7]') == 'AB21' and 'uart_tx' not in pins
    timing=(ROOT/'board/timing.fdc').read_text()
    phy_timing=[]
    for bank in range(2):
        phy_timing += [f'set_multicycle_path 2 -from [get_clocks ddrphy_sysclk] -to [get_clocks phy_dq_sysclk_{bank}]',
            f'set_clock_uncertainty {{0.4}} -from [get_clocks {{ddrphy_sysclk}}] -to [get_clocks {{phy_dq_sysclk_{bank}}}] -setup -hold',
            f'set_clock_uncertainty {{0.4}} -from [get_clocks {{phy_dq_sysclk_{bank}}}] -to [get_clocks {{ddrphy_sysclk}}] -setup -hold']
    checks['reference_phy_multicycle_and_uncertainty_preserved']=all(line in timing for line in phy_timing)
    checks['iic_pins_preserved'] = pin_map.get('iic_scl') == 'P19' and pin_map.get('iic_sda') == 'R19'
    bad_parts = []
    for name in ['pcie_test', 'ddr3', 'PLL_CLK', 'fifo_2_ddr', 'ddr_2_fifo',
                 'pango_acore_fetch', 'pango_acore_ram', 'pango_multiplier_ip', 'pango_pool_sum_ram']:
        header = ET.parse(ROOT / 'ipcore' / name / (name + '.idf')).getroot().find('header')
        if [header.findtext(x) for x in ['device', 'package', 'speedgrade']] != ['PG2L100H', 'FBG484', '-6']:
            bad_parts.append(name)
    checks['all_active_ip_parts_match'] = not bad_parts
    checks['groute_seed_is_3'] = '(_option groute_seed (_integer 3))' in pds
    checks['preprocess_sources_registered'] = all(name in files for name in (
        'rtl/video/preprocess/hdmi_tensor_capture.v','rtl/video/preprocess/rgb888_pool96.v',
        'rtl/video/preprocess/rgb_mean240.v','rtl/video/preprocess/pool_sum_ram.v',
        'ipcore/pango_pool_sum_ram/pango_pool_sum_ram.idf'))
    checks['physical_preprocess_enabled'] = '.ENABLE_PREPROCESS(1)' in (ROOT/'board/acore_dual_top.v').read_text()
    preserved = ['Acore.v', 'ALU.v', 'CSR.v', 'decoder.v', 'GPR_matrix.v',
                 'acore_pair.v', 'acore_forward.v', 'acore_fetch_queue.v', 'multiply_unit.v']
    preserved += ['rk_iic/' + p.name for p in (ROOT / 'rtl/rk_iic').glob('*.v')]
    changed_core = []
    for name in preserved:
        path = 'rtl/' + name
        old = subprocess.check_output(['git', 'show', '20f4da7:' + path], cwd=ROOT)
        if digest(old) != digest((ROOT / path).read_bytes()):
            changed_core.append(path)
    checks['own_acore_and_iic_unchanged_from_m1'] = not changed_core
    manifest = json.loads((ROOT / 'docs/video_import_manifest.json').read_text())
    stale = []
    for item in manifest['files']:
        if digest((ROOT / item['destination']).read_bytes()) != item['current_normalized_sha256']:
            stale.append(item['destination'])
        if args.reference_root:
            original = (args.reference_root / item['source']).read_bytes()
            if hashlib.sha256(original).hexdigest() != item['sha256']:
                stale.append('reference:' + item['source'])
    checks['import_manifest_hashes_match'] = not stale
    for name in ['build_acore_dual.ps1', 'build_fpga.ps1']:
        checks[name + '_guards_root_project'] = 'board/acore_video_platform.v' in (ROOT / 'scripts' / name).read_text()
    report = dict(passed=all(checks.values()), scope='static paths, pins, IP parts and source provenance',
                  pds_parser_run=False, pds_implementation_run=False, hardware_tested=False,
                  checks=checks, missing_files=missing, duplicate_files=duplicates,
                  missing_pds_metadata=missing_metadata,
                  missing_pin_constraints=sorted(ports - hsst_lanes - set(pin_map)),
                  unknown_pin_ports=sorted(set(pin_map) - ports), duplicate_pins=repeated_pins,
                  bad_ip_parts=bad_parts, changed_core=changed_core, stale_imports=stale,
                  general_io_pins=len(pin_map), imported_files=len(manifest['files']),
                  desktop_source_verified=bool(args.reference_root))
    dest = ROOT / 'reports/video_integration/project.json'
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(report, indent=2) + '\n')
    print('M2 static project:', 'PASS' if report['passed'] else 'FAIL')
    if not report['passed']:
        print(json.dumps(report, indent=2))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
