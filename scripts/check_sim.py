import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", choices=("TB_memory_core", "TB_mem", "TB_board"))
    args = parser.parse_args()
    output = ROOT / "build/sim/behavioral"
    output.mkdir(parents=True, exist_ok=True)
    rtl = [path for path in sorted((ROOT / "rtl").glob("*.v"))
           if path.name not in ("ROM_core.v", "memory_core.v")]
    rtl += sorted((ROOT / "sim/models").glob("*.v"))
    board = sorted((ROOT / "board").glob("*.v"))
    defines = ["-DNO_WAVES", '-DPROG_FILE="firmware/rom.hex"',
               '-DDATA_FILE="firmware/ram_bytes.hex"']
    for name in ([args.test] if args.test else ("TB_memory_core", "TB_mem", "TB_board")):
        executable = output / (name + ".vvp")
        subprocess.run(["iverilog", "-g2012", "-s", name, *defines,
                        "-o", str(executable), str(ROOT / "sim" / (name + ".v")),
                        *map(str, rtl + board)], cwd=ROOT, check=True)
        result = subprocess.run(["vvp", str(executable)], cwd=ROOT, capture_output=True, text=True)
        report = result.stdout + result.stderr
        (output / (name + ".log")).write_text(report)
        print(report, end="", flush=True)
        if result.returncode or "PASS" not in report or "ERROR" in report or "FATAL" in report:
            raise RuntimeError(f"{name} failed")


if __name__ == "__main__":
    main()
