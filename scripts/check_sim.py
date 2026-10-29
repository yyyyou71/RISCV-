import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    tests = ("TB_memory_core", "TB_mem", "TB_board", "TB_coremark", "TB_rk_iic", "TB_board_iic", "TB_cpu_iic", "TB_rk_cpu_bus")
    parser.add_argument("--test", choices=tests)
    parser.add_argument("--core", choices=("single", "acore_dual"), default="single",
                        help="CPU configuration for TB_cpu_iic")
    args = parser.parse_args()
    if args.core != "single" and args.test != "TB_cpu_iic":
        parser.error("--core acore_dual is supported with --test TB_cpu_iic")
    output = ROOT / "build/sim/behavioral"
    output.mkdir(parents=True, exist_ok=True)
    rtl = [path for path in sorted((ROOT / "rtl").glob("*.v"))
           if path.name not in ("ROM_core.v", "memory_core.v", "multiplier_core.v", "acore_fetch_memory.v", "MuxKeyInternal.v",
                                "multiply_adder.v", "multiply_adder_w8a16.v", "video_async_fifo.v")]
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
        test_defines = defines
        if name in ("TB_board", "TB_board_iic", "TB_cpu_iic"):
            app = "iic_service" if name == "TB_cpu_iic" else "selftest"
            images = ROOT / "build/firmware" / app / "images"
            subprocess.run(["python3", str(ROOT / "scripts/build_firmware.py"),
                            "--app", app, "--image-dir", str(images)], cwd=ROOT, check=True)
            rel = images.relative_to(ROOT).as_posix()
            test_defines = ["-DNO_WAVES", '-DPROG_FILE="' + rel + '/rom.hex"',
                            '-DDATA_FILE="' + rel + '/ram_bytes.hex"']
        parameters = (["-PTB_cpu_iic.ENABLE_DUAL=1"]
                      if name == "TB_cpu_iic" and args.core == "acore_dual" else [])
        subprocess.run(["iverilog", "-g2012", "-s", name, *test_defines, *parameters,
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
