import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from validate_coremark import validate

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verilator", default=shutil.which("verilator"))
    parser.add_argument("--require-duration", action="store_true")
    parser.add_argument("--core", choices=("single", "evolve5"), default="single")
    args = parser.parse_args()
    environment = os.environ.copy()
    if not args.verilator:
        local = ROOT / "build/tools/verilator-4.038/usr"
        args.verilator = str(local / "bin/verilator_bin")
        environment["VERILATOR_ROOT"] = str(local / "share/verilator")
    manifest_name = "manifest_evolve5.json" if args.core == "evolve5" else "manifest.json"
    manifest = json.loads((ROOT / "build/firmware" / manifest_name).read_text())
    output = ROOT / "build/sim" / ("verilator-evolve5" if args.core == "evolve5" else "verilator")
    output.mkdir(parents=True, exist_ok=True)
    sources = [path for path in sorted((ROOT / "rtl").glob("*.v"))
               if path.name not in ("ROM_core.v", "memory_core.v", "multiplier_core.v")]
    sources += sorted((ROOT / "sim/models").glob("*.v"))
    sources += sorted((ROOT / "board").glob("*.v"))
    sources += [ROOT / "sim/board_probe.v"]
    includes = []
    if args.core == "evolve5":
        from evolve5_sources import design_sources
        sources = design_sources() + [ROOT / "sim/evolve5_models.v", ROOT / "sim/evolve5_probe.v"]
        includes = ["-I" + str(ROOT / "cores/evolve5/rtl"), "-CFLAGS", "-DEVOLVE5=1"]
    command = [args.verilator, "--cc", "--exe", "--build", "-j", "4", "-O3", "-Wno-fatal",
               "--timescale-override", "1ns/1ps",
               "--top-module", "board_probe", "--Mdir", str(output / "obj_dir"),
               '-DPROG_FILE="firmware/rom.hex"', '-DDATA_FILE="firmware/ram_bytes.hex"',
               *includes, *map(str, sources), str(ROOT / "sim/verilator_coremark.cpp")]
    with (output / "compile.log").open("w") as stream:
        subprocess.run(command, cwd=ROOT, env=environment, stdout=stream, stderr=subprocess.STDOUT,
                       check=True, timeout=600)
    started = time.monotonic()
    result = subprocess.run([str(output / "obj_dir/Vboard_probe"),
                             str(manifest["iterations"] * 600000 + 5000000)],
                            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=1200)
    report = result.stdout + result.stderr
    (output / "TB_coremark.log").write_text(report)
    print(report, flush=True)
    if result.returncode:
        raise RuntimeError("Verilator simulation failed")
    record = validate(report, manifest)
    if args.require_duration and record["short_run"]:
        raise ValueError("CoreMark measured interval is shorter than ten seconds")
    record.update(simulator="Verilator behavioral memories and multiplier, actual UART bitstream",
                  wall_seconds=time.monotonic() - started)
    prefix = "evolve5-" if args.core == "evolve5" else ""
    destination = ROOT / "reports/coremark" / (prefix + manifest["mode"] + f"-{manifest['iterations']}-verilator.json")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(record, indent=2) + "\n")
    destination.with_suffix(".log").write_text(report)
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
