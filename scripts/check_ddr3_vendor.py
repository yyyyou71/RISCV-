"""Optional black-box oracle run; requires licensed ModelSim and original Pango IP.

Reads vendor sources in place; all generated files go into build/ddr3/vendor.
"""
import argparse
import os
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ip", type=Path, default=Path.home() / "Desktop/ziguang-fpga2/ipcore/ddr3")
    p.add_argument("--modelsim", type=Path, default=Path(r"C:\diskE\modelsim\win64"))
    p.add_argument("--pds", type=Path,
                   default=Path(r"C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1"))
    args = p.parse_args()
    if os.name == "nt" and not os.environ.get("MGLS_LICENSE_FILE"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            os.environ["MGLS_LICENSE_FILE"] = winreg.QueryValueEx(key, "MGLS_LICENSE_FILE")[0]
    out = ROOT / "build/ddr3/vendor"
    out.mkdir(parents=True, exist_ok=True)

    def execute(tool, arguments, log):
        result = subprocess.run([str(args.modelsim / (tool + ".exe")), *map(str, arguments)],
                                cwd=out, capture_output=True, text=True,
                                errors="replace", timeout=240)
        report = result.stdout + result.stderr
        (out / log).write_text(report, encoding="utf-8")
        if result.returncode or "** Error" in report or "** Fatal" in report:
            raise RuntimeError(f"Vendor {tool} failed: {out / log}\n{report[-3500:]}")
        return report

    if not (out / "work").exists():
        execute("vlib", ["work"], "vlib.log")
    if not (out / "modelsim.ini").exists():
        execute("vmap", ["-c"], "vmap.log")
    # Both generated controller and Micron chip are named ddr3 in this export.
    # Rename ONLY the chip's module declaration in a build-directory copy.
    chip_source = args.ip / "example_design/bench/mem/ddr3.v"
    renamed_chip = out / "micron_ddr3_model.v"
    chip_text, substitutions = re.subn(r"\bmodule\s+ddr3\s*\(", "module ddr3_model (",
                                       chip_source.read_text(), count=1)
    if substitutions != 1:
        raise ValueError("Expected one Micron ddr3 module declaration")
    renamed_chip.write_text(chip_text, encoding="utf-8")
    sources = [args.ip / "ddr3.v", args.ip / "ddr3_ddrphy_top.v", renamed_chip]
    original = args.ip / "sim/modelsim/sim_file_list.f"
    for raw in original.read_text().splitlines():
        line = raw.strip()
        if line.startswith("./../../sim_lib/"):
            sources.append((original.parent / line).resolve())
        elif "/arch/vendor/pango/" in line:
            suffix = line[line.index("arch/vendor/pango/"):]
            sources.append(args.pds / suffix)
    vendor = args.pds / "arch/vendor/pango/verilog/simulation"
    # The exported script compiles ADC internals separately.
    sources.extend((vendor / "modelsim10.2c/adc_e2_source_codes").glob("*.vp"))
    sources.append(ROOT / "sim/ddr3/tb_ddr3.sv")
    sources = list(dict.fromkeys(sources))
    missing = [str(path) for path in sources if not path.exists()]
    if missing:
        raise FileNotFoundError("Missing vendor sources:\n" + "\n".join(missing))
    filelist = out / "oracle.f"
    filelist.write_text("\n".join('"' + path.as_posix() + '"' for path in sources), encoding="utf-8")
    execute("vlog", ["-sv", "-mfcu", "-incr", "-suppress", "2902", "-f", filelist,
                     "-y", vendor, "+libext+.v",
                     "+incdir+" + (args.ip / "example_design/bench/mem").as_posix(),
                     "+incdir+" + original.parent.as_posix(),
                     "+define+DDR3_VENDOR_ORACLE+IPS_DDR_SPEEDUP_SIM+RTL_SIM+den4096Mb+x16+sg187E"],
            "compile.log")
    report = execute("vsim", ["-c", "-quiet", "-suppress", "3486,3680,3781", "+nowarn1",
                              "-onfinish", "exit", "-l", "transcript.log", "-wlf", "oracle.wlf",
                              "work.tb_ddr3", "-do",
                              "onerror {quit -code 1}; run -all; quit -code 1"], "run.log")
    if "PASS tb_ddr3" not in report:
        raise RuntimeError(f"Vendor oracle did not pass: {out / 'run.log'}\n{report[-3500:]}")
    print("\n".join(line for line in report.splitlines() if "PASS tb_ddr3" in line))


if __name__ == "__main__":
    main()
