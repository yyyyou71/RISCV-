import argparse
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {"performance": (0xe9f5, 0xe714, 0x1fd7, 0x8e3a),
            "validation": (0x18f2, 0xe3c1, 0x0747, 0x8d84)}
SHORT_ERROR = "ERROR! Must execute for at least 10 secs for a valid result!"


def validate(report, manifest):
    report = re.sub(r"(?m)^# ?", "", report).replace("\r", "")

    def field(pattern, base=10):
        values = re.findall(pattern, report, re.MULTILINE)
        if len(values) != 1:
            raise ValueError(f"Missing or duplicate CoreMark field: {pattern}")
        return int(values[0], base)

    crcs = tuple(field(rf"^{name}\s*:\s*0x([0-9a-fA-F]+)\s*$", 16)
                 for name in ("seedcrc", r"\[0\]crclist", r"\[0\]crcmatrix", r"\[0\]crcstate"))
    if crcs != EXPECTED[manifest["mode"]]:
        raise ValueError(f"CoreMark CRC mismatch: {crcs}")
    ticks = field(r"^Total ticks\s*:\s*(\d+)\s*$")
    iterations = field(r"^Iterations\s*:\s*(\d+)\s*$")
    if iterations != manifest["iterations"] or not ticks or field(r"^CoreMark Size\s*:\s*(\d+)\s*$") != 666:
        raise ValueError("CoreMark timing, iterations or workload size mismatch")
    frequency = manifest["clock_hz"]
    for name, expected in (("Total time (secs)", ticks / frequency),
                           ("Iterations/Sec", iterations * frequency / ticks)):
        values = re.findall(rf"^{re.escape(name)}\s*:\s*(\d+\.\d+)\s*$", report, re.MULTILINE)
        if len(values) != 1 or not math.isclose(float(values[0]), expected, rel_tol=1e-8, abs_tol=1e-6):
            raise ValueError(f"Incorrect floating-point report: {name}")
    errors = [line.strip() for line in report.splitlines() if "ERROR" in line]
    short = ticks < 10 * frequency
    if short:
        if errors != [SHORT_ERROR] or "Errors detected" not in report:
            raise ValueError("Unexpected diagnostics in short CoreMark run")
    elif errors or "Errors detected" in report or "Correct operation validated." not in report:
        raise ValueError("CoreMark reported validation errors")
    if "Cannot validate" in report or "COREMARK DONE" not in report or "PASS: CoreMark board exit_code=0" not in report:
        raise ValueError("CoreMark did not complete cleanly")
    record = {"mode": manifest["mode"], "iterations": iterations, "cycles": ticks,
            "clock_hz": frequency, "seconds": ticks / frequency, "crc_pass": True,
            "short_run": short, "hardware_tested": False,
            "iterations_per_second": iterations * frequency / ticks,
            "coremark_per_mhz": iterations * 1000000 / ticks,
            "firmware_rom_sha256": manifest["rom_sha256"],
            "firmware_ram_sha256": manifest["ram_sha256"]}
    if manifest.get("core") == "acore_dual":
        counters = re.findall(r"^BENCH COUNTERS: cycles=(\d+) retired=(\d+) second=(\d+)\s*$", report, re.MULTILINE)
        if len(counters) != 1:
            raise ValueError("Missing measured retirement counters")
        measured, retired, secondary = map(int, counters[0])
        if measured != ticks or not secondary or secondary >= retired:
            raise ValueError("Invalid Acore measurement window or no secondary retirement")
        record.update(retired_instructions=retired, secondary_retired=secondary, ipc=retired/ticks)
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--manifest", type=Path, default=ROOT / "build/firmware/manifest.json")
    parser.add_argument("--require-duration", action="store_true")
    args = parser.parse_args()
    result = validate(args.log.read_text(errors="replace"), json.loads(args.manifest.read_text()))
    if args.require_duration and result["short_run"]:
        raise ValueError("Measured interval is shorter than ten seconds")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
