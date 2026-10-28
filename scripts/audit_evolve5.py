import hashlib
import json
from pathlib import Path
import re
import shutil
from audit_build import require, final_timing
from evolve5_sources import design_sources

ROOT = Path(__file__).resolve().parents[1]


def main():
    build = ROOT / "build/pds-evolve5"
    manifest = json.loads((ROOT / "build/firmware/manifest_evolve5.json").read_text())
    console = (build / "console.log").read_text(errors="replace")
    require(not re.search(r"^E:", console, re.MULTILINE) and "Generating Programming File done." in console,
            "EVOLVE5 PDS implementation did not finish cleanly")
    timing = (build / "place_route/board_top_timing_summary_after_hold_fix.txt").read_text()
    require("All Constraints Met" in timing, "EVOLVE5 timing failed")
    corners = re.findall(r"sys_clk\s+sys_clk\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)", timing)
    require(len(corners) == 4 and all(float(slack) >= 0 and float(total) == 0 and int(failing) == 0
                                    for slack, total, failing in corners), "EVOLVE5 setup/hold corner failed")
    standalone_timing = final_timing(build)
    netlist = (build / "synthesize/board_top_syn.vm").read_text(errors="replace")
    drm = len(re.findall(r"^\s+GTP_DRM36K_E1\s", netlist, re.MULTILINE))
    apm = len(re.findall(r"^\s+GTP_APM_E2\s", netlist, re.MULTILINE))
    require(drm == 16 and apm == 4, "Expected 8+8 DRM and four official multiplier APMs")
    multiply = re.search(r"module rv32_muldiv\b.*?endmodule", netlist, re.DOTALL)
    require(multiply and not re.search(r"\b(?:quotient|remainder|divisor)\b", multiply.group()),
            "Disabled divider state remains in the synthesized multiplier unit")
    reset = re.search(r"module board_reset\b(.*?)endmodule", netlist, re.DOTALL).group(1)
    hold = re.search(r"GTP_DFF\s*/\* hold_reset \*/ #\((.*?)\)\s+hold_reset_vname", reset, re.DOTALL)
    require(hold and '.GRS_EN("TRUE")' in hold.group(1) and ".INIT(1'b1)" in hold.group(1),
            "EVOLVE5 power-on reset initialization lost")
    synchronizers = re.findall(
        r"GTP_DFF_C\s*/\* \\release_sync\[(?:0|1)\]\s+\*/ #\((.*?)\)\s+\\release_sync", reset, re.DOTALL)
    require(len(synchronizers) == 2 and all('.GRS_EN("TRUE")' in item and ".INIT(1'b0)" in item
                                           for item in synchronizers), "EVOLVE5 reset synchronizers lost initial values")
    for mode in ("performance", "validation"):
        evidence = json.loads((ROOT / "reports/coremark" / f"evolve5-{mode}-1-modelsim.json").read_text())
        require(evidence["crc_pass"] and evidence["secondary_retired"] > 0, "Official IP CRC/dual retirement failed")
        for name, expected in evidence["rtl_sha256"].items():
            require(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, f"Stale EVOLVE5 regression: {name}")
    simulation = json.loads((ROOT / "reports/coremark" /
                             f"evolve5-{manifest['mode']}-{manifest['iterations']}-verilator.json").read_text())
    require(simulation["crc_pass"] and simulation["secondary_retired"] > 0,
            "EVOLVE5 final firmware simulation failed")
    require(simulation["firmware_rom_sha256"] == manifest["rom_sha256"] and
            simulation["firmware_ram_sha256"] == manifest["ram_sha256"], "EVOLVE5 final firmware mismatch")
    if manifest["iterations"] >= 2048:
        require(not simulation["short_run"], "EVOLVE5 benchmark interval is below ten seconds")
    ip_report = (ROOT / "build/sim/modelsim-evolve5/TB_evolve5_ip.log").read_text(errors="replace")
    require("PASS: EVOLVE5 ROM/RAM images" in ip_report and "Errors: 0" in ip_report,
            "Final EVOLVE5 IP image/arithmetic checks did not pass")
    memory_report = (ROOT / "build/sim/modelsim-evolve5/TB_evolve5_memory.log").read_text(errors="replace")
    require("PASS: EVOLVE5 burst memory" in memory_report and "Errors: 0" in memory_report,
            "EVOLVE5 FPGA memory adapter checks did not pass")
    control_report = (ROOT / "reports/evolve5/control.log").read_text(errors="replace")
    require("PASS: EVOLVE5 control" in control_report and "FATAL" not in control_report,
            "EVOLVE5 control/interrupt firmware checks did not pass")
    inputs = design_sources() + [ROOT / "cores/evolve5/rtl/rv32_defs.vh",
                                ROOT / "board/pins.fdc", ROOT / "board/timing.fdc",
                                ROOT / "scripts/implement_evolve5.tcl", build / "evolve5_design.v",
                                ROOT / "firmware/evolve5_rom.hex", ROOT / "firmware/evolve5_ram.hex"]
    for name in ("pango_evolve_rom", "pango_evolve_ram", "pango_evolve_mul"):
        directory = ROOT / "ipcore" / name
        inputs += [directory / (name + ".idf"), directory / (name + ".v")]
        inputs += sorted((directory / "rtl").rglob("*.v"))
    bitstream = build / "generate_bitstream/board_top.sbit"
    require(bitstream.is_file() and bitstream.stat().st_mtime >= max(path.stat().st_mtime for path in inputs),
            "Missing or stale EVOLVE5 bitstream")
    destination = ROOT / "download/coremark_evolve5_25mhz.sbit"
    shutil.copy2(bitstream, destination)
    utilization = (build / "place_route/board_top.prr").read_text(errors="replace")
    record = {"status": "implementation_and_simulation_passed", "hardware_tested": False,
              "final_standalone_sta": standalone_timing,
              "core": "EVOLVE5", "device": "PG2L100H", "package": "FBG484", "clock_hz": 25000000,
              "isa": "RV32I+Zmmul+Zicsr", "enable_div": 0, "max_issue": 2,
              "btb_entries": 32, "icache_bytes": 1024, "dcache_bytes": 1024,
              "cache_tag_storage": "resettable_ff", "placement_clustering": False, "route_seed": 1,
              "lut": sum(map(int, re.findall(r"\|\s+LUT\s+\|\s+(\d+)\s+\|", utilization))),
              "flip_flops": sum(map(int, re.findall(r"\|\s+FF\s+\|\s+(\d+)\s+\|", utilization))),
              "drm36k": drm, "apm": apm, "setup_slow_slack_ns": float(corners[0][0]),
              "hold_slow_slack_ns": float(corners[1][0]), "setup_fast_slack_ns": float(corners[2][0]),
              "hold_fast_slack_ns": float(corners[3][0]), "coremark": simulation,
              "bitstream": destination.relative_to(ROOT).as_posix(),
              "bitstream_bytes": destination.stat().st_size,
              "bitstream_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
              "input_sha256": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in inputs}}
    path = ROOT / "reports/coremark/evolve5-implementation.json"
    path.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({name: value for name, value in record.items() if name != "input_sha256"}, indent=2))


if __name__ == "__main__":
    main()
