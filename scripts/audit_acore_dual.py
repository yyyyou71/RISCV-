import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
from audit_build import final_timing, require

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-long-simulation", action="store_true")
    args = parser.parse_args()
    build = ROOT / "build/pds-acore-dual"
    top = "acore_dual_top"
    console = (build / "console.log").read_text(errors="replace")
    require(not re.search(r"^E:", console, re.MULTILINE) and "Generating Programming File done." in console,
            "Acore dual PDS did not finish cleanly")
    summary = (build / "place_route" / (top + "_timing_summary_after_hold_fix.txt")).read_text()
    corners = re.findall(r"sys_clk\s+sys_clk\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)", summary)
    require(len(corners) == 4 and all(float(s) >= 0 and float(t) == 0 and int(n) == 0 for s,t,n in corners),
            "Acore dual implementation has setup/hold violations")
    timing = final_timing(build, top)
    standalone_report = (build / "place_route" / (top + ".rtr")).read_text(errors="replace")
    require("All Constraints Met" in summary and "All Constraints Met" in standalone_report,
            "Timing summary contains unmet constraints")
    netlist = (build / "synthesize" / (top + "_syn.vm")).read_text(errors="replace")
    blocks = {name: len(re.findall(r"^\s+" + name + r"\s", netlist, re.MULTILINE))
              for name in ("GTP_DRM36K_E1", "GTP_APM_E2")}
    require(blocks == {"GTP_DRM36K_E1": 24, "GTP_APM_E2": 4}, "Unexpected memory or multiply IP mapping")
    reset = re.search(r"module board_reset\b(.*?)endmodule", netlist, re.DOTALL).group(1)
    hold = re.search(r"GTP_DFF\s+/\* hold_reset \*/ #\((.*?)\)\s+hold_reset_vname", reset, re.DOTALL)
    require(hold and '.GRS_EN("TRUE")' in hold.group(1) and ".INIT(1'b1)" in hold.group(1),
            "Power-on reset initial state was lost")
    synchronizers = re.findall(r"GTP_DFF_C\s+/\* \\release_sync\[(?:0|1)\]\s+\*/ #\((.*?)\)\s+\\release_sync",
                               reset, re.DOTALL)
    require(len(synchronizers) == 2 and all('.GRS_EN("TRUE")' in item and ".INIT(1'b0)" in item
                                           for item in synchronizers), "Reset synchronizer initial states were lost")
    for mode in ("performance", "validation"):
        evidence = json.loads((ROOT / f"reports/coremark/acore_dual-{mode}-1-modelsim.json").read_text())
        require(evidence["crc_pass"] and evidence["secondary_retired"] > 0, "Official IP CoreMark failed")
        for name, expected in evidence["rtl_sha256"].items():
            require(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, f"Stale RTL regression: {name}")
    manifest = json.loads((ROOT / "build/firmware/manifest_acore_dual.json").read_text())
    for name, expected in manifest["sources"].items():
        require(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, f"Stale firmware source: {name}")
    if args.skip_long_simulation:
        evidence = json.loads((ROOT / f"reports/coremark/acore_dual-{manifest['mode']}-1-modelsim.json").read_text())
    else:
        evidence = json.loads((ROOT / f"reports/coremark/acore_dual-{manifest['mode']}-{manifest['iterations']}-verilator.json").read_text())
        require(evidence["crc_pass"] and not evidence["short_run"] and evidence["secondary_retired"] > 0,
                "Final CoreMark long run failed")
        require(evidence["firmware_rom_sha256"] == manifest["rom_sha256"] and
                evidence["firmware_ram_sha256"] == manifest["ram_sha256"], "Final firmware changed since simulation")
        for name, expected in evidence["rtl_sha256"].items():
            require(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, f"Stale long-run RTL: {name}")
    for name in ("TB_acore_fetch_ip", "TB_acore_ram_ip", "TB_multiplier_ip"):
        log = (ROOT / "build/sim/modelsim-acore_dual" / (name + ".log")).read_text(errors="replace")
        require("PASS" in log and "Errors: 0" in log and "Fatal:" not in log, f"IP check failed: {name}")
    for name in ("differential", "interrupts"):
        checks = json.loads((ROOT / f"reports/acore_dual/{name}.json").read_text())
        require(checks["cases"] and all(item["result"] == "pass" for item in checks["cases"]), f"Missing Acore regression: {name}")
        for source, expected in checks["source_sha256"].items():
            require(hashlib.sha256((ROOT / source).read_bytes()).hexdigest() == expected, f"Stale regression source: {source}")
    inputs = sorted((ROOT / "rtl").glob("*.v")) + sorted((ROOT / "board").glob("*"))
    inputs += [ROOT / "firmware/acore_dual_rom.hex", ROOT / "firmware/acore_dual_ram.hex",
               ROOT / "scripts/implement_acore_dual.tcl"]
    for name in ("pango_acore_fetch", "pango_acore_ram", "pango_multiplier_ip"):
        folder = ROOT / "ipcore" / name
        inputs += [folder / (name + ".idf"), folder / (name + ".v")]
        inputs += sorted((folder / "rtl").rglob("*.v"))
    bitstream = build / "generate_bitstream" / (top + ".sbit")
    require(bitstream.is_file() and bitstream.stat().st_mtime >= max(p.stat().st_mtime for p in inputs),
            "Missing or stale Acore dual bitstream")
    utilization = (build / "place_route" / (top + ".prr")).read_text(errors="replace")
    counts = {name.lower(): sum(map(int, re.findall(r"\|\s+" + name + r"\s+\|\s+(\d+)\s+\|", utilization)))
              for name in ("LUT", "FF")}
    destination = ROOT / "download/coremark_acore_dual_25mhz.sbit"
    destination.parent.mkdir(exist_ok=True)
    shutil.copy2(bitstream, destination)
    report_directory = ROOT / "reports/acore_dual"
    report_directory.mkdir(parents=True, exist_ok=True)
    for source, name in ((build / "place_route" / (top + ".prr"), "resources.prr"),
                         (build / "place_route" / (top + ".rtr"), "timing.rtr"),
                         (build / "place_route" / (top + "_timing_summary_after_hold_fix.txt"), "timing_summary.txt")):
        shutil.copy2(source, report_directory / name)
    record = dict(status="implementation_and_short_simulation_passed" if args.skip_long_simulation else "implementation_and_simulation_passed", hardware_tested=False,
                  core="Acore constrained in-order dual issue", isa="rv32i_zmmul", cache=False,
                  device="PG2L100H", package="FBG484", clock_hz=25000000, baud_rate=115200,
                  drm36k=24, apm=4, **counts, final_standalone_sta=timing,
                  coremark=evidence, long_simulation_run=not args.skip_long_simulation,
                  final_firmware=dict(iterations=manifest["iterations"], mode=manifest["mode"],
                                      rom_sha256=manifest["rom_sha256"], ram_sha256=manifest["ram_sha256"]),
                  bitstream=destination.relative_to(ROOT).as_posix(),
                  bitstream_sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),
                  router_hold_repair_message=("Hold violation fix failed" if "Hold violation fix failed" in console else None),
                  hold_repair_target_ps=200,
                  resource_report="reports/acore_dual/resources.prr", timing_report="reports/acore_dual/timing.rtr",
                  input_sha256={p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs})
    (ROOT / "reports/acore_dual/implementation.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({k: v for k, v in record.items() if k != "input_sha256"}, indent=2))


if __name__ == "__main__":
    main()
