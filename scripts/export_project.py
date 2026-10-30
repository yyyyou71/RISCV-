import argparse
from datetime import datetime
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PDS = Path(r"C:\diskE\FPGA_Learning\PGenvironment\PDS_2022.2-SP6.1")


def group_end(text, start):
    depth = 0
    quoted = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if escaped:
            escaped = False
            continue
        if quoted and char == '\\':
            escaped = True
            continue
        if char == '"':
            quoted = not quoted
        if not quoted:
            depth += (char == '(') - (char == ')')
            if depth == 0:
                return index
    raise ValueError('Unbalanced PDS expression')


def complete_source_metadata(project, directory):
    """Supply PDS-required timestamps without changing sources or flow options.

    A balanced S-expression is insufficient: PDS 2022.2 requires _timespec on
    _file, _ip, and _ip_source_item entries, including the IP parent itself.
    """
    edits = []
    counts = dict(_file=0, _ip=0, _ip_source_item=0)
    pattern = r'\((_(?:file|ip|ip_source_item))\s+"([^"]+)"'
    for match in re.finditer(pattern, project):
        kind, filename = match.groups()
        end = group_end(project, match.start())
        tail = project[match.end():end]
        has_timestamp = (re.match(r'\s*\(_timespec\b', tail) if kind == '_ip'
                         else re.search(r'\(_timespec\b', tail))
        if has_timestamp:
            continue
        path = directory / filename
        timestamp = datetime.fromtimestamp(path.stat().st_mtime).strftime('%Y-%m-%dT%H:%M:%S')
        line_start = project.rfind('\n', 0, match.start()) + 1
        indent = re.match(r'[ \t]*', project[line_start:match.start()]).group()
        insert = match.end()
        if kind == '_file':
            fmt = re.search(r'\(_format\b', tail)
            if not fmt:
                raise ValueError(f'Missing PDS _format: {filename}')
            insert = group_end(project, match.end() + fmt.start()) + 1
        value = '\n' + indent + '    (_timespec "' + timestamp + '")'
        if not project[insert:end].strip() and '\n' not in project[insert:end]:
            value += '\n' + indent
        edits.append((insert, value))
        counts[kind] += 1
    for insert, value in sorted(edits, reverse=True):
        project = project[:insert] + value + project[insert:]
    return project, counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pds-root", type=Path, default=DEFAULT_PDS)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, default=ROOT / "rv32I.pds")
    parser.add_argument("--no-compile", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve()
    destination = args.destination.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
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
    project, supplied = complete_source_metadata(project, destination.parent)
    destination.write_text(project, encoding="utf-8")
    if any(supplied.values()):
        print(f"PDS_REQUIRED_METADATA_ADDED {supplied}")
    if args.no_compile:
        print(f"PROJECT_EXPORTED_NOT_COMPILED {destination}")
        return

    if os.name == "nt" and not os.environ.get("PANGO_LICENSE_FILE"):
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            os.environ["PANGO_LICENSE_FILE"] = winreg.QueryValueEx(key, "PANGO_LICENSE_FILE")[0]
    result = subprocess.run([str(args.pds_root / "bin/pds_shell.exe"),
                             "-project", str(destination), "-run", "compile"],
                            cwd=destination.parent, capture_output=True, text=True, errors="replace", timeout=120)
    output = result.stdout + result.stderr
    name = "root" if destination.name == "rv32I.pds" else destination.stem
    log = ROOT / "build/project_check" / (name + "_compile.log")
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(output, encoding="utf-8")
    if result.returncode or re.search(r"^E:", output, re.MULTILINE) or 'Process "Compile" done.' not in output:
        raise RuntimeError(f"Root PDS project validation failed; see {log}")
    print(f"ROOT_PROJECT_PASS {destination}")


if __name__ == "__main__":
    main()
