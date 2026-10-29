import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def final_timing(build, top="board_top"):
    report = (build / "place_route" / (top + ".rtr")).read_text(errors="replace")
    paths = re.findall(r"Path Type\s+: (max|min) \((slow|fast) corner\).*?"
                       r"Slack\s+\((MET|VIOLATED)\)\s+(-?[\d.]+)", report, re.DOTALL)
    expected = {(kind, corner) for kind in ("max", "min") for corner in ("slow", "fast")}
    require({(kind, corner) for kind, corner, status, slack in paths} == expected,
            "Final standalone STA is missing a setup/hold corner")
    require(all(status == "MET" and float(slack) >= 0 for kind, corner, status, slack in paths),
            "Final standalone STA has violated paths")
    return {("setup" if kind == "max" else "hold") + "_" + corner + "_slack_ns":
            min(float(slack) for path_kind, path_corner, status, slack in paths
                if path_kind == kind and path_corner == corner) for kind, corner in sorted(expected)}


def main():
    build = ROOT / "build/pds"
    console = (build / "console.log").read_text(encoding="utf-8", errors="replace")
    require(not re.search(r"^E:", console, re.MULTILINE), "PDS reported an error")
    require("Generating Programming File done." in console, "No completed bitstream generation")
    timing = (build / "place_route/board_top_timing_summary_after_hold_fix.txt").read_text()
    require("All Constraints Met" in timing, "PDS timing constraints failed")
    clocks = re.findall(r"sys_clk\s+sys_clk\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)", timing)
    require(len(clocks) == 4, "Expected setup/hold reports for slow and fast corners")
    require(all(float(slack) >= 0 and float(total) == 0 and int(failing) == 0
                for slack, total, failing in clocks), "Timing has failing endpoints")
    standalone_timing = final_timing(build)
    netlist = (build / "synthesize/board_top_syn.vm").read_text(errors="replace")
    require(len(re.findall(r"^\s+GTP_DRM36K_E1\s", netlist, re.MULTILINE)) == 24,
            "Expected 8 ROM and 16 RAM DRM36K instances")
    reset = re.search(r"module board_reset\b(.*?)endmodule", netlist, re.DOTALL).group(1)
    hold = re.search(r"GTP_DFF\s+/\* hold_reset \*/ #\((.*?)\)\s+hold_reset_vname",
                     reset, re.DOTALL)
    require(hold and '.GRS_EN("TRUE")' in hold.group(1) and ".INIT(1'b1)" in hold.group(1),
            "Reset hold register did not retain its configuration-time initial value")
    synchronizers = re.findall(
        r"GTP_DFF_C\s+/\* \\release_sync\[(?:0|1)\]\s+\*/ #\((.*?)\)\s+\\release_sync",
        reset, re.DOTALL)
    require(len(synchronizers) == 2 and all('.GRS_EN("TRUE")' in item and ".INIT(1'b0)" in item
                                           for item in synchronizers),
            "Reset release synchronizers lost their initial values")
    manifest = json.loads((ROOT / "build/firmware/manifest.json").read_text())
    tests = ["TB_storage_images", "TB_memory_core", "TB_mem", "TB_multiplier_ip"]
    if manifest["application"] == "selftest":
        tests.append("TB_board")
    else:
        for mode in ("performance", "validation"):
            evidence = json.loads((ROOT / "reports/coremark" / f"{mode}-1-modelsim.json").read_text())
            require(evidence["crc_pass"], f"Official IP CoreMark {mode} CRC did not pass")
            for name, expected in evidence["rtl_sha256"].items():
                require(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected,
                        f"Official IP CoreMark regression is stale: {name}")
        evidence = json.loads((ROOT / "reports/coremark" / f"{manifest['mode']}-{manifest['iterations']}-verilator.json").read_text())
        require(evidence["crc_pass"] and evidence["firmware_rom_sha256"] == manifest["rom_sha256"]
                and evidence["firmware_ram_sha256"] == manifest["ram_sha256"],
                "Final CoreMark firmware has not passed simulation")
        if manifest["iterations"] >= 1000:
            require(not evidence["short_run"], "CoreMark measured interval is shorter than ten seconds")
    require(len(re.findall(r"^\s+GTP_APM_E2\s", netlist, re.MULTILINE)) == 4,
            "Expected four Logos2 APM blocks for the 33x33 multiplier")
    for name in tests:
        report = (ROOT / "build/sim/modelsim" / (name + ".log")).read_text(errors="replace")
        require("PASS" in report and "Errors: 0" in report and "Fatal:" not in report,
                f"Official IP simulation did not pass: {name}")
    bitstream = build / "generate_bitstream/board_top.sbit"
    require(bitstream.is_file() and bitstream.stat().st_size > 0, "No nonempty bitstream")
    inputs = sorted((ROOT / "rtl").glob("*.v")) + sorted((ROOT / "board").glob("*"))
    inputs = [path for path in inputs if path.is_file()]
    inputs += sorted((ROOT / "rtl/rk_iic").glob("*.v"))
    inputs += [ROOT / "firmware/rom.hex", ROOT / "firmware/ram.hex"]
    for name in ("pango_rom", "pango_ram", "pango_multiplier_ip"):
        directory = ROOT / "ipcore" / name
        inputs += [directory / (name + ".idf"), directory / (name + ".v")]
        inputs += sorted((directory / "rtl").rglob("*.v"))
    require(bitstream.stat().st_mtime >= max(path.stat().st_mtime for path in inputs),
            "Bitstream is older than its design inputs; rebuild with build_fpga.ps1")
    destination = ROOT / ("download/coremark_single_25mhz.sbit" if manifest["application"] == "coremark"
                          else "download/selftest_25mhz.sbit")
    destination.parent.mkdir(exist_ok=True)
    shutil.copy2(bitstream, destination)
    utilization = (build / "place_route/board_top.prr").read_text(errors="replace")
    luts = sum(map(int, re.findall(r"\|\s+LUT\s+\|\s+(\d+)\s+\|", utilization)))
    flip_flops = sum(map(int, re.findall(r"\|\s+FF\s+\|\s+(\d+)\s+\|", utilization)))
    record = {
        "status": "implementation_and_simulation_passed", "hardware_tested": False,
        "final_standalone_sta": standalone_timing,
        "upstream_commit": "9bd2479b0ce167a77bfa4ca22e1969984f06a236",
        "application": manifest["application"], "core": "Acore", "isa": "rv32i_zmmul",
        "iterations": manifest["iterations"], "seed_mode": manifest["mode"], "apm": 4,
        "device": "PG2L100H", "package": "FBG484", "speedgrade": "-6",
        "clock_hz": 25000000, "baud_rate": 115200, "lut": luts, "flip_flops": flip_flops,
        "drm36k": 24, "setup_slow_slack_ns": float(clocks[0][0]),
        "hold_slow_slack_ns": float(clocks[1][0]),
        "setup_fast_slack_ns": float(clocks[2][0]), "hold_fast_slack_ns": float(clocks[3][0]),
        "bitstream": str(destination.relative_to(ROOT)), "bitstream_bytes": destination.stat().st_size,
        "bitstream_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        "input_sha256": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in inputs},
    }
    report = ROOT / "reports/migration.json"
    report.parent.mkdir(exist_ok=True)
    report.write_text(json.dumps(record, indent=2) + "\n")
    if manifest["application"] == "coremark":
        (ROOT / "reports/coremark/single-implementation.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({name: value for name, value in record.items() if name != "input_sha256"}, indent=2))


if __name__ == "__main__":
    main()
