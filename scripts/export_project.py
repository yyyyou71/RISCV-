import argparse
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PDS = Path(r"C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pds-root", type=Path, default=DEFAULT_PDS)
    args = parser.parse_args()
    source = ROOT / "build/pds/rv32I.pds"
    destination = ROOT / "rv32I.pds"
    project = source.read_text(encoding="utf-8")
    project = re.sub(r"(?ms)^([ \t]*)\(_(?:db_)?output\b.*?^\1\)[ \t]*\n", "", project)
    project = re.sub(
        r"(?ms)^        \(_widget wgt_edit_placement_cons\b.*?^        \)\n",
        "        (_widget wgt_edit_placement_cons\n"
        "            (_attribute _click_to_run (_switch ON))\n"
        "        )\n", project)
    project = re.sub(r"(\(_gci_state \(_integer )\d+", r"\g<1>0", project)

    def rebase(match):
        path = Path(match.group(2))
        if not path.is_absolute():
            path = source.parent / path
        if not path.is_file():
            raise FileNotFoundError(f"PDS project references a missing file: {path}")
        relative = Path(os.path.relpath(path.resolve(), destination.parent)).as_posix()
        return match.group(1) + relative + match.group(3)

    project = re.sub(r'(\(_(?:file|ip|ip_source_item)\s+")([^"]+)(")', rebase, project)
    destination.write_text(project, encoding="utf-8")

    if os.name == "nt" and not os.environ.get("PANGO_LICENSE_FILE"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            os.environ["PANGO_LICENSE_FILE"] = winreg.QueryValueEx(key, "PANGO_LICENSE_FILE")[0]
    result = subprocess.run([str(args.pds_root / "bin/pds_shell.exe"),
                             "-project", str(destination), "-run", "compile"],
                            cwd=ROOT, capture_output=True, text=True, errors="replace", timeout=120)
    output = result.stdout + result.stderr
    log = ROOT / "build/project_check/root_compile.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(output, encoding="utf-8")
    if result.returncode or re.search(r"^E:", output, re.MULTILINE) or 'Process "Compile" done.' not in output:
        raise RuntimeError(f"Root PDS project validation failed; see {log}")
    print(f"ROOT_PROJECT_PASS {destination}")


if __name__ == "__main__":
    main()
