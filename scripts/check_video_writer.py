"""Short writer-counter/CDC test; no model inference or physical DDR verification."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    out = ROOT / 'build/hdmi-writer'
    out.mkdir(parents=True, exist_ok=True)
    files = ['sim/video/TB_video_writer_diagnostic.v',
             'rtl/video/video_writer_diagnostic.v', 'rtl/video/ddr3_write_ctrl_lite.v',
             'sim/video/fifo_2_ddr_model.v']
    binary = out / 'check.vvp'
    commands = [['iverilog', '-g2012', '-s', 'TB_video_writer_diagnostic',
                 '-o', str(binary), *files], ['vvp', str(binary)]]
    output = ''
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
        output += result.stdout + result.stderr
        if result.returncode:
            raise RuntimeError(output)
    (out / 'short_test.log').write_text(output)
    if 'PASS ' not in output:
        raise RuntimeError(output)
    report = dict(passed=True, scope=__doc__, hardware_tested=False,
                  sources={name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in files})
    dest = ROOT / 'reports/video_integration/hdmi_writer_checks.json'
    dest.write_text(json.dumps(report, indent=2)+'\n')
    print(output, end='')


if __name__ == '__main__':
    main()
