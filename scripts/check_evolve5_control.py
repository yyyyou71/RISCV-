from pathlib import Path
import subprocess
from evolve5_sources import ROOT, design_sources


def main():
    output = ROOT / "build/evolve5-control"
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32im", "-mno-div", "-mabi=ilp32",
                    "-mno-relax", "-nostdlib", "-nostartfiles", "-T", str(ROOT / "cores/evolve5/link.ld"),
                    str(ROOT / "cores/evolve5/tests/control.S"), "-o", str(output / "control.elf")], check=True)
    subprocess.run(["riscv64-unknown-elf-objcopy", "-j", ".text", "-O", "binary",
                    str(output / "control.elf"), str(output / "control.bin")], check=True)
    data = (output / "control.bin").read_bytes()
    data += bytes((-len(data)) % 4)
    (output / "control.hex").write_text("".join(
        f"{int.from_bytes(data[offset:offset+4], 'little'):08x}\n" for offset in range(0, len(data), 4))
        + "00000013\n" * ((32768 - len(data)) // 4))
    sources = design_sources() + [ROOT / "sim/evolve5_models.v", ROOT / "sim/TB_evolve5_control.v"]
    subprocess.run(["iverilog", "-g2012", "-s", "TB_evolve5_control", "-I", str(ROOT / "cores/evolve5/rtl"),
                    "-o", str(output / "control.vvp"), *map(str, sources)], cwd=ROOT, check=True)
    result = subprocess.run(["vvp", str(output / "control.vvp")], cwd=ROOT, capture_output=True, text=True, timeout=60)
    report = result.stdout + result.stderr
    print(report)
    if result.returncode or "PASS: EVOLVE5 control" not in report or "FATAL" in report:
        raise RuntimeError("EVOLVE5 control regression failed")
    destination = ROOT / "reports/evolve5/control.log"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(report)


if __name__ == "__main__":
    main()
