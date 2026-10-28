import json
import hashlib
from pathlib import Path
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/acore-dual"


def run(command):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def program(seed):
    rng = random.Random(seed)
    lines = [".option norvc", ".option norelax", ".text", ".globl _start", "_start:", "li x31, 0x10000"]
    lines += [f"li x{r}, {rng.randrange(-1000000, 1000000)}" for r in range(1, 31)]
    lines += ["addi x1,x0,11", "addi x2,x0,22", "add x3,x1,x2", "addi x4,x0,44",
              "add x5,x2,x4", "add x6,x1,x3", "addi x1,x1,1", "addi x1,x1,2",
              "sw x1,0(x31)", "lw x7,0(x31)", "addi x8,x0,5", "add x9,x7,x8",
              "addi x10,x0,1", "addi x11,x0,2", "lw x10,0(x31)", "add x12,x10,x11",
              "mul x13,x12,x11", "addi x14,x0,19", "add x15,x13,x14",
              "addi x0,x1,1", "add x16,x0,x2", "auipc x17,0", "lui x18,0x81234"]
    for n in range(24):
        lines += [f"li x30, {rng.randrange(2, 8)}", f"loop{n}:"]
        for _ in range(45):
            rd, a, b = (rng.randrange(0, 30) for _ in range(3))
            kind = rng.randrange(12)
            if kind < 4:
                op = rng.choice(("add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu"))
                lines.append(f"{op} x{rd},x{a},x{b}")
            elif kind < 7:
                op = rng.choice(("addi", "andi", "ori", "xori", "slti", "sltiu"))
                lines.append(f"{op} x{rd},x{a},{rng.randrange(-2048, 2048)}")
            elif kind == 7:
                lines.append(f"{rng.choice(('slli','srli','srai'))} x{rd},x{a},{rng.randrange(32)}")
            elif kind == 8:
                lines += [f"{rng.choice(('sw','sh','sb'))} x{a},{rng.randrange(0, 64)*4}(x31)",
                          f"{rng.choice(('lw','lh','lhu','lb','lbu'))} x{rd},{rng.randrange(0,64)*4}(x31)"]
            elif kind == 9:
                lines.append(f"{rng.choice(('mul','mulh','mulhu','mulhsu'))} x{rd},x{a},x{b}")
            elif kind == 10:
                lines += [f"beq x{a},x{b},skip{n}_{_}", f"addi x{rd},x{a},1", f"skip{n}_{_}:"]
            else:
                lines += [f"jal x{rd},jump{n}_{_}", "sw x1,0(x0)", f"jump{n}_{_}:"]
        lines += ["addi x30,x30,-1", f"bne x30,x0,loop{n}"]
    lines += ["la x20,indirect", "jalr x21,0(x20)", "sw x1,0(x0)", "indirect:",
              "li x29,0x30000", ".globl test_end", "test_end: sw x0,0(x29)", "1: j 1b"]
    return "\n".join(lines) + "\n"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    records = []
    for seed in (7, 19, 103, 997):
        source = OUT / f"random-{seed}.S"
        source.write_text(program(seed))
        elf = source.with_suffix(".elf")
        run(["riscv64-unknown-elf-gcc", "-march=rv32im", "-mabi=ilp32", "-nostdlib", "-mno-relax",
             "-Ttext=0", "-o", elf, source])
        binary = source.with_suffix(".bin")
        run(["riscv64-unknown-elf-objcopy", "-j", ".text", "-O", "binary", elf, binary])
        data = binary.read_bytes()
        if len(data) > 32768:
            raise ValueError("Random program exceeds ROM")
        image = source.with_suffix(".hex")
        data = data + bytes.fromhex("13000000") * ((32768-len(data)) // 4)
        image.write_text("".join(f"{int.from_bytes(data[i:i+4], 'little'):08x}\n" for i in range(0, len(data), 4)))
        ram = OUT / "zero.data"
        ram.write_text("00\n" * 65536)
        stop_pc = next(line.split()[0] for line in run(["riscv64-unknown-elf-nm", elf]).splitlines()
                       if line.endswith(" test_end"))
        executable = OUT / f"compare-{seed}.vvp"
        run(["iverilog", "-g2012", "-s", "TB_acore_compare", "-y", ROOT / "sim/models", "-y", ROOT / "rtl",
             f'-DPROG_FILE="{image}"', f'-DDATA_FILE="{ram}"', "-o", executable, ROOT / "sim/TB_acore_compare.v"])
        report = run(["vvp", executable, f"+stop_pc={stop_pc}"])
        traces = [[], []]
        for line in (OUT / "trace.txt").read_text().splitlines():
            index, *entry = line.split()
            traces[int(index)].append(tuple(int(field, 16) for field in entry))
        if traces[0] != traces[1]:
            for n, (a, b) in enumerate(zip(*traces)):
                if a != b:
                    raise AssertionError(f"seed {seed} instruction {n}: single {a}, dual {b}")
            raise AssertionError(f"Trace length mismatch: {list(map(len, traces))}")
        if "PASS" not in report:
            raise RuntimeError(report)
        record = {"seed": seed, "retirements_compared": len(traces[0]), "ram_bytes_compared": 65536,
                  "result": "pass", "summary": next(line for line in report.splitlines() if line.startswith("PASS"))}
        print(json.dumps(record), flush=True)
        records.append(record)
    destination = ROOT / "reports/acore_dual/differential.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / "rtl").glob("*.v")) + sorted((ROOT / "sim/models").glob("*.v"))
    sources += [ROOT / "sim/TB_acore_compare.v", Path(__file__).resolve()]
    destination.write_text(json.dumps({"cases": records, "source_sha256": {
        path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
