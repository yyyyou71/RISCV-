from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def design_sources():
    sources = sorted((ROOT / "cores/evolve5/rtl").rglob("*.v"))
    sources = [path for path in sources if path.name != "rv32_soc_memory.v"]
    return sources + [ROOT / "cores/evolve5/fpga/rv32_soc_memory.v",
                      ROOT / "cores/evolve5/board_top.v", ROOT / "board/board_reset.v"]


def prepare():
    destination = ROOT / "build/pds-evolve5/evolve5_design.v"
    destination.parent.mkdir(parents=True, exist_ok=True)
    contents = [(ROOT / "cores/evolve5/rtl/rv32_defs.vh").read_text()]
    contents += [path.read_text().replace('`include "rv32_defs.vh"', "") for path in design_sources()]
    body = "\n".join(contents)
    if not destination.exists() or destination.read_text(encoding="utf-8") != body:
        destination.write_text(body, encoding="utf-8")
    portable = ROOT / "cores/evolve5/generated/evolve5_design.v"
    portable.parent.mkdir(parents=True, exist_ok=True)
    if not portable.exists() or portable.read_text(encoding="utf-8") != body:
        portable.write_text(body, encoding="utf-8")
    print(destination)


if __name__ == "__main__":
    prepare()
