import argparse
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PDS = Path(r"C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1")


def prepare(pds, kind, instance, overrides):
    category = "apm" if kind in ("ipm2l_mult", "ipm2l_multadd") else "ram"
    model = pds / f"ip/module_ip/ipm2l_flex_{category}/ipm2l_flex_{category}_eval" / kind
    index = ET.parse(model / "index.xml").getroot()
    document = ET.Element("ip_inst")
    header = ET.SubElement(document, "header")
    values = {name: index.findtext(f"header/{name}")
              for name in ("vendor", "id", "display_name", "name", "version")}
    values.update(instance=instance, family="Logos2", device="PG2L100H",
                  package="FBG484", speedgrade="-6")
    for name, value in values.items():
        ET.SubElement(header, name).text = value
    parameters = ET.SubElement(document, "param_list")
    for definition in index.findall("param_list/param"):
        name = definition.findtext("name")
        parameter = ET.SubElement(parameters, "param")
        ET.SubElement(parameter, "name").text = name
        ET.SubElement(parameter, "value").text = str(overrides.get(name, definition.findtext("default")))
    ET.SubElement(document, "pin_list")
    ET.SubElement(document, "file_list")
    destination = ROOT / "ipcore" / instance
    destination.mkdir(parents=True, exist_ok=True)
    path = destination / (instance + ".idf")
    ET.indent(document, space="    ")
    ET.ElementTree(document).write(path, encoding="utf-8", xml_declaration=True)
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pds-root", type=Path, default=DEFAULT_PDS)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--only", choices=("pango_rom", "pango_ram", "pango_multiplier_ip", "pango_acore_fetch", "pango_acore_ram"))
    parser.add_argument("--core", choices=("single", "acore_dual"), default="single")
    args = parser.parse_args()
    if os.name == "nt" and not os.environ.get("PANGO_LICENSE_FILE"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            os.environ["PANGO_LICENSE_FILE"] = winreg.QueryValueEx(key, "PANGO_LICENSE_FILE")[0]
    common = {"CAS_MODE_SEL": "DRM36K", "CAS_MODE": "36K", "RESET_TYPE": "SYNC",
              "INIT_EN": "1", "INIT_FORMAT": "HEX", "POWER_OPT": "0"}
    rom = dict(common, ADDR_WIDTH="13", DATA_WIDTH="32", OUTPUT_REG="0",
               ADDR_STROBE_EN="1", INIT_FILE=(ROOT / "firmware/rom.hex").as_posix())
    ram = dict(common, A_ADDR_WIDTH="14", B_ADDR_WIDTH="14", A_DATA_WIDTH="32",
               B_DATA_WIDTH="32", WR_BYTE_EN="1", BYTE_SIZE="8", A_BE_WIDTH="4",
               B_BE_WIDTH="4", A_OUTPUT_REG="0", B_OUTPUT_REG="0",
               A_WRITE_MODE="TRANSPARENT_WRITE", B_WRITE_MODE="TRANSPARENT_WRITE",
               INIT_FILE=(ROOT / "firmware/ram.hex").as_posix())
    multiplier = dict(ASIZE="33", BSIZE="33", A_SIGNED="1", B_SIGNED="1",
                      ASYNC_RST="0", ASYNC_RST_BOOL="0", PIPE_STATUS="3",
                      INREG_EN="0", PIPEREG_EN_1="1", PIPEREG_EN_2="1",
                      PIPEREG_EN_3="1", OUTREG_EN="0", OPTIMAL_TIMING="0",
                      OPTIMAL_TIMING_BOOL="0", ADVANCED_BOOL="0")
    configurations = [("ipm2l_rom", "pango_rom", rom), ("ipm2l_dpram", "pango_ram", ram),
                      ("ipm2l_mult", "pango_multiplier_ip", multiplier)]
    if args.core == "acore_dual":
        fetch = dict(ram, A_ADDR_WIDTH="13", B_ADDR_WIDTH="13", A_CLK_EN="1", B_CLK_EN="1",
                     INIT_FILE=(ROOT / "firmware/acore_dual_rom.hex").as_posix())
        ram["INIT_FILE"] = (ROOT / "firmware/acore_dual_ram.hex").as_posix()
        configurations = [("ipm2l_dpram", "pango_acore_fetch", fetch),
                          ("ipm2l_dpram", "pango_acore_ram", ram),
                          ("ipm2l_mult", "pango_multiplier_ip", multiplier)]
    for kind, name, configuration in configurations:
        if args.only and args.only != name:
            continue
        if "INIT_FILE" in configuration and not Path(configuration["INIT_FILE"]).is_file():
            raise FileNotFoundError("Build the firmware before generating memory IP")
        path = prepare(args.pds_root, kind, name, configuration)
        print(path, flush=True)
        if not args.prepare_only:
            subprocess.run([str(args.pds_root / "bin/ip_generate.exe"), "-i", str(path),
                            "-disable-syn"], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
