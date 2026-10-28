import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    tests = ("TB_memory_core", "TB_mem", "TB_board", "TB_coremark", "TB_rk_iic")
    parser.add_argument("--test", choices=tests)
    args = parser.parse_args()
    output = ROOT / "build/sim/behavioral"
    output.mkdir(parents=True, exist_ok=True)
    rtl = [path for path in sorted((ROOT / "rtl").glob("*.v"))
           if path.name not in ("ROM_core.v", "memory_core.v", "multiplier_core.v", "acore_fetch_memory.v")]
    rtl += sorted((ROOT / "sim/models").glob("*.v"))
    rtl += sorted((ROOT / "rtl/rk_iic").glob("*.v"))
    board = sorted((ROOT / "board").glob("*.v"))
    defines = ["-DNO_WAVES", '-DPROG_FILE="firmware/rom.hex"',
               '-DDATA_FILE="firmware/ram_bytes.hex"']
    selected = [args.test] if args.test else ["TB_memory_core", "TB_mem", "TB_rk_iic"]
    manifest = ROOT / "build/firmware/manifest.json"
    if not args.test and manifest.exists() and json.loads(manifest.read_text())["application"] == "selftest":
        selected.append("TB_board")
    for name in selected:
        executable = output / (name + ".vvp")
        subprocess.run(["iverilog", "-g2012", "-s", name, *defines,
                        "-o", str(executable), str(ROOT / "sim" / (name + ".v")),
                        *map(str, rtl + board)], cwd=ROOT, check=True)
        result = subprocess.run(["vvp", str(executable)], cwd=ROOT, capture_output=True, text=True)
        report = result.stdout + result.stderr
        (output / (name + ".log")).write_text(report)
        print(report, end="", flush=True)
        if result.returncode or "PASS" not in report or "FATAL" in report:
            raise RuntimeError(f"{name} failed")
        if name == "TB_coremark":
            from validate_coremark import validate
            validate(report, json.loads(manifest.read_text()))


if __name__ == "__main__":
    main()
