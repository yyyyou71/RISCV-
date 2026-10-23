#!/usr/bin/env python3
"""生成乘法测试程序，复用 TB_Acore，并由宿主机核对实际输出。"""
from pathlib import Path
import random
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/multiply"
PREFIX = "riscv64-unknown-elf-"
MASK = 0xffffffff


def run(args):
    return subprocess.run([str(x) for x in args], cwd=ROOT, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout


def expected_product(a, b, operation):
    # Python 任意精度整数作为参考，避免依赖处理器自己的乘法来检查乘法。
    if operation in ("mulh", "mulhsu") and a & 0x80000000:
        a -= 1 << 32
    if operation == "mulh" and b & 0x80000000:
        b -= 1 << 32
    return ((a * b) >> (0 if operation == "mul" else 32)) & MASK


def build_program():
    lines = [".text", ".globl _start", "_start:", "li t6, 0x30000", "li s0, 0x10000"]
    expected = []

    def emit(*instructions):
        lines.extend(instructions)

    def report(register, value):
        emit(f"sw {register}, 4(t6)")
        expected.append(value & MASK)

    # 每条乘法紧跟 store，直接验证 EX/MEM 结果前递；轮换 rd 与 rs1/rs2 重叠。
    edges = [0, 1, 2, MASK, 0x80000000, 0x7fffffff, 0x80000001]
    rng = random.Random(0x52563332)
    pairs = [(a, b) for a in edges for b in edges]
    pairs.extend((rng.getrandbits(32), rng.getrandbits(32)) for _ in range(60))
    operations = ("mul", "mulh", "mulhsu", "mulhu")
    for index, (a, b) in enumerate(pairs):
        for operation in operations:
            dest = ("t2", "t0", "t1")[index % 3]
            emit(f"li t0, {a}", f"li t1, {b}", f"{operation} {dest}, t0, t1")
            report(dest, expected_product(a, b, operation))

    # 连续乘法、相同目的寄存器、两路输入来自同一结果，以及乘法后立即算术。
    emit("li t0, 3", "li t1, 7", "mul t2, t0, t1", "mul t2, t2, t1",
         "mul t3, t2, t2", "addi t3, t3, 1")
    report("t3", 147 * 147 + 1)

    # load-use 后启动乘法，两路 load 输入和 load 到 rs2 的情况分别覆盖。
    emit("li t0, 0x80000000", "sw t0, 0(s0)", "lw t0, 0(s0)", "mulh t2, t0, t0")
    report("t2", 0x40000000)
    emit("li t0, 0xffffffff", "lw t1, 0(s0)", "mulhsu t2, t0, t1")
    report("t2", MASK)

    # 乘法结果马上作为访存基址，而不是只作为被写入的数据。
    emit("li t0, 256", "mul t2, t0, t0", "lw t3, 0(t2)")
    report("t3", 0x80000000)

    # 乘法到分支前递，错误路径上的乘法不得改变寄存器或提前启动。
    emit("li t0, 3", "li t1, 7", "li t3, 99", "mul t2, t0, t1",
         "beq t2, t3, fail", "bne t2, t3, taken", "mul t3, t0, t1", "taken:")
    report("t3", 99)
    emit("jal zero, skip_mul", "mul t3, t0, t1", "skip_mul:")
    report("t3", 99)

    # 循环训练分支预测器，预测取指与乘法暂停同时出现。
    emit("li s1, 12", "li t0, 3", "li t1, 7", "multiply_loop:",
         "mul t2, t0, t1", "addi t0, t0, 1", "addi s1, s1, -1",
         "bne s1, zero, multiply_loop")
    report("t2", 98)

    # x0 不写回、不前递；两个源寄存器都为 x0 时输出为零。
    emit("mul zero, t0, t1", "addi t2, zero, 5")
    report("t2", 5)
    emit("mulhu t2, zero, zero")
    report("t2", 0)

    # 当前未接入非法指令异常：未支持的除法编码不能误写目标寄存器。
    for instruction in ("div", "divu", "rem", "remu"):
        emit("li t2, 99", f"{instruction} t2, t0, t1")
        report("t2", 99)

    emit("li t0, 1", "sw t0, 0(t6)", "halt: j halt", "fail:",
         "sw zero, 0(t6)", "j fail")
    source = OUT / "multiply.S"
    source.write_text("\n".join(lines) + "\n")
    elf = OUT / "multiply.elf"
    run([PREFIX + "gcc", "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-nostdlib",
         "-nostartfiles", "-T", ROOT / "link.ld", "-o", elf, source])
    (OUT / "multiply.dis").write_text(run([PREFIX + "objdump", "-d", elf]))
    binary = OUT / "multiply.bin"
    run([PREFIX + "objcopy", "-j", ".text", "-O", "binary", elf, binary])
    data = binary.read_bytes()
    (OUT / "multiply.hex").write_text("".join(
        f"{int.from_bytes(data[i:i+4], 'little'):08x}\n" for i in range(0, len(data), 4)))
    (OUT / "multiply.data").write_text("00\n")
    return expected


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    unit_sim = OUT / "TB_multiplier.out"
    run(["iverilog", "-g2012", "-s", "TB_multiplier", "-o", unit_sim,
         ROOT / "Iverilog/TB_multiplier.v", ROOT / "vsrc/multiply_unit.v",
         ROOT / "vsrc/multiplier_core.v"])
    unit_log = run(["vvp", unit_sim])
    (OUT / "unit.log").write_text(unit_log)
    print(unit_log, end="", flush=True)
    expected = build_program()
    for stages in range(1, 6):
        sim = OUT / f"TB_Acore-{stages}.out"
        # 通过库目录按需载入 CPU 模块，沿用原有测试台、RAM 和 MMIO 行为。
        run(["iverilog", "-g2012", "-s", "TB_Acore", "-y", ROOT / "vsrc", "-DNO_WAVES",
             f'-DPROG_FILE="{OUT / "multiply.hex"}"',
             f'-DDATA_FILE="{OUT / "multiply.data"}"',
             f"-PTB_Acore.MUL_PIPE_STAGES={stages}", "-PTB_Acore.ENABLE_DIV=0",
             "-o", sim, ROOT / "Iverilog/TB_Acore.v"])
        report = run(["vvp", sim])
        (OUT / f"acore-{stages}.log").write_text(report)
        actual = [int(x, 16) for x in re.findall(r"\[print\]\s+\d+\s+\(0x([0-9a-fA-F]+)\)", report)]
        if actual != expected:
            for index, (got, want) in enumerate(zip(actual, expected)):
                if got != want:
                    raise ValueError(f"第 {index} 个输出错误：got={got:08x}, expected={want:08x}")
            raise ValueError(f"输出数量错误：got={len(actual)}, expected={len(expected)}")
        if not re.search(r"PASS\s+exit_code=1\b", report):
            raise ValueError("Acore 没有成功退出")
        print(f"PASS: TB_Acore, {stages} 级乘法 IP，{len(expected)} 个输出全部匹配", flush=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout, end="")
        raise
