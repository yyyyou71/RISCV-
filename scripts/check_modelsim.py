import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
from validate_coremark import validate

ROOT = Path(__file__).resolve().parents[1]


def execute(arguments, log, directory=ROOT):
    result = subprocess.run([argument.as_posix() if isinstance(argument, Path) else str(argument)
                             for argument in arguments], cwd=directory,
                            capture_output=True, text=True, errors="replace", timeout=1800)
    report = result.stdout + result.stderr
    log.write_text(report, encoding="utf-8")
    if result.returncode or "** Error" in report or "** Fatal" in report:
        print(report[-8000:])
        raise RuntimeError(f"ModelSim failed: {log}")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--modelsim", type=Path, default=Path(r"C:\diskE\modelsim\win64"))
    parser.add_argument("--pds-root", type=Path,
                        default=Path(r"C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1"))
    parser.add_argument("--tests", nargs="+")
    parser.add_argument("--core", choices=("single", "evolve5"), default="single")
    args = parser.parse_args()
    if os.name == "nt" and not os.environ.get("MGLS_LICENSE_FILE"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            os.environ["MGLS_LICENSE_FILE"] = winreg.QueryValueEx(key, "MGLS_LICENSE_FILE")[0]
    output = ROOT / "build/sim" / ("modelsim-evolve5" if args.core == "evolve5" else "modelsim")
    output.mkdir(parents=True, exist_ok=True)
    library = output / "work"
    if not library.exists():
        execute([args.modelsim / "vlib.exe", library], output / "vlib.log")
    configuration = output / "modelsim.ini"
    if not configuration.exists():
        execute([args.modelsim / "vmap.exe", "-c"], output / "configuration.log", output)
    execute([args.modelsim / "vmap.exe", "-modelsimini", configuration, "work", library],
            output / "mapping.log")
    sources = sorted((ROOT / "rtl").glob("*.v")) + sorted((ROOT / "board").glob("*.v"))
    sources += sorted((ROOT / "rtl/rk_iic").glob("*.v"))
    includes = []
    names = ("pango_rom", "pango_ram", "pango_multiplier_ip")
    tests = args.tests or ["TB_storage_images", "TB_memory_core", "TB_mem", "TB_multiplier_ip", "TB_coremark"]
    if args.core == "evolve5":
        from evolve5_sources import design_sources
        sources = design_sources()
        includes.append("+incdir+" + str(ROOT / "cores/evolve5/rtl"))
        names = ("pango_evolve_rom", "pango_evolve_ram", "pango_evolve_mul")
        tests = args.tests or ["TB_evolve5_coremark"]
    for name in names:
        directory = ROOT / "ipcore" / name
        document = ET.parse(directory / (name + ".idf"))
        sources += [directory / item.attrib["pathname"]
                    for item in document.findall("file_list/source/file")]
        includes.append("+incdir+" + str(directory / "rtl"))
    vendor = args.pds_root / "arch/vendor/pango/verilog/simulation"
    sources += [vendor / "GTP_DRM36K_E1.v", vendor / "GTP_APM_E2.v", vendor / "GTP_GRS.v"]
    benches = [ROOT / "sim" / (name + ".v")
               for name in tests]
    execute([args.modelsim / "vlog.exe", "-sv", "-modelsimini", configuration,
             "-work", "work", "+define+PANGO_IP+NO_WAVES",
             *includes, *sources, *benches], output / "compile.log")
    for bench in benches:
        report = execute([args.modelsim / "vsim.exe", "-c", "-quiet", "-onfinish", "exit",
                          "-l", output / (bench.stem + "_transcript.log"),
                          "-wlf", output / (bench.stem + ".wlf"),
                          "-modelsimini", configuration, "work." + bench.stem, "-do",
                          "onerror {quit -code 1}; run -all; quit -code 1"],
                         output / (bench.stem + ".log"))
        print("\n".join(line for line in report.splitlines()
                        if "PASS" in line or "Errors:" in line), flush=True)
        if "PASS" not in report or "Fatal:" in report:
            raise RuntimeError(f"No successful result for {bench.stem}")
        if bench.stem in ("TB_coremark", "TB_evolve5_coremark"):
            manifest_name = "manifest_evolve5.json" if args.core == "evolve5" else "manifest.json"
            manifest = json.loads((ROOT / "build/firmware" / manifest_name).read_text())
            result = validate(report, manifest)
            result["simulator"] = "ModelSim official memory and multiplier IP"
            design = design_sources() if args.core == "evolve5" else sorted((ROOT / "rtl").glob("*.v")) + sorted((ROOT / "board").glob("*.v"))
            result["rtl_sha256"] = {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                                    for path in design}
            prefix = "evolve5-" if args.core == "evolve5" else ""
            destination = ROOT / "reports/coremark" / (prefix + manifest["mode"] + f"-{manifest['iterations']}-modelsim.json")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(json.dumps(result, indent=2) + "\n")
            destination.with_suffix(".log").write_text(report, encoding="utf-8")
            print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
