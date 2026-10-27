import argparse
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def execute(arguments, log, directory=ROOT):
    result = subprocess.run([argument.as_posix() if isinstance(argument, Path) else str(argument)
                             for argument in arguments], cwd=directory,
                            capture_output=True, text=True, errors="replace", timeout=180)
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
    args = parser.parse_args()
    if os.name == "nt" and not os.environ.get("MGLS_LICENSE_FILE"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            os.environ["MGLS_LICENSE_FILE"] = winreg.QueryValueEx(key, "MGLS_LICENSE_FILE")[0]
    output = ROOT / "build/sim/modelsim"
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
    for name in ("pango_rom", "pango_ram"):
        directory = ROOT / "ipcore" / name
        document = ET.parse(directory / (name + ".idf"))
        sources += [directory / item.attrib["pathname"]
                    for item in document.findall("file_list/source/file")]
        includes.append("+incdir+" + str(directory / "rtl"))
    vendor = args.pds_root / "arch/vendor/pango/verilog/simulation"
    sources += [vendor / "GTP_DRM36K_E1.v", vendor / "GTP_GRS.v"]
    benches = [ROOT / "sim" / (name + ".v")
               for name in ("TB_storage_images", "TB_memory_core", "TB_mem", "TB_board")]
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


if __name__ == "__main__":
    main()
