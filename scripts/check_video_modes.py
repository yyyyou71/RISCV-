"""Short host tests for RAW/AI control and firmware leases; no AI RTL rerun."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    out = ROOT / 'build/direct-capture'
    out.mkdir(parents=True, exist_ok=True)
    commands = [
        ('rk_clients', ['make', '-C', 'csrc/rk_fspi', 'all', 'test']),
        ('firmware_compile', ['gcc', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-ffunction-sections', '-fdata-sections', 'sim/video/test_video_direct_capture.c',
            'firmware/video_present.c', '-Wl,--gc-sections', '-o', str(out / 'firmware_test')]),
        ('firmware_modes', [str(out / 'firmware_test')]),
    ]
    cases = []
    try:
        for name, command in commands:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=90)
            log = result.stdout + result.stderr
            (out / (name + '.log')).write_text(log)
            if result.returncode:
                raise RuntimeError(log[-6000:])
            cases.append(dict(name=name, passed=True))
            print(name + ': PASS', flush=True)
    finally:
        # These binaries are x86 host checks, not RK ARM executables.
        subprocess.run(['make', '-C', 'csrc/rk_fspi', 'clean'], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL)
    files = ['firmware/video_diagnostic.c', 'firmware/preprocess_capture.h',
             'firmware/video_present.c', 'firmware/video_present.h',
             'firmware/ai_network.c', 'firmware/ai_network.h',
             'csrc/rk_fspi/rk_video_app.c', 'csrc/rk_fspi/comm_protocol.h',
             'csrc/rk_fspi/rk_comm_cli.c', 'csrc/rk_fspi/test_comm_cli.c', 'csrc/rk_fspi/test_video_app.c',
             'sim/video/test_video_direct_capture.c', 'board/acore_video_platform.v',
             'rtl/video_timing_monitor.v']
    result = dict(passed=True, scope=__doc__, cases=cases, hardware_tested=False,
        sources={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in files})
    (ROOT/'reports/video_integration/raw_ai_modes_checks.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
