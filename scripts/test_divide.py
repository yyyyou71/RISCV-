#!/usr/bin/env python3
"""检查除法器边界、Acore 总开关，并比较同一程序的软件/硬件除法周期。"""
from pathlib import Path
import random
import re
import subprocess
import sys

# 复用测试工具时不在源代码目录生成字节码缓存。
sys.dont_write_bytecode = True
from test_multiply import ROOT, PREFIX, MASK, run

OUT = ROOT / "build/divide"
CPU_NAMES = ["Acore", "CSR", "PC", "ROM", "ROM_core", "decoder", "ALU", "multiply_unit",
             "multiplier_core", "memory", "memory_core", "GPR_matrix", "Reg",
             "hazard_detection_unit", "branch_predictor"]


def reference(a, b, operation):
    if not b:
        return a if operation.startswith("rem") else MASK
    if operation in ("div", "rem"):
        a = a - (1 << 32) if a & 0x80000000 else a
        b = b - (1 << 32) if b & 0x80000000 else b
    quotient = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        quotient = -quotient
    remainder = a - quotient * b
    return (remainder if operation.startswith("rem") else quotient) & MASK


def build_program(enabled):
    lines = [".text", ".globl _start", "_start:", "li t6, 0x30000", "li s0, 0x10000"]
    expected = []

    def emit(*instructions):
        lines.extend(instructions)

    def report(register, value):
        emit(f"sw {register}, 4(t6)")
        expected.append(value & MASK)

    edges = [0, 1, 2, 3, MASK, 0x80000000, 0x7fffffff, 0xfffffffd]
    pairs = [(a, b) for a in edges for b in edges]
    rng = random.Random(0x444956)
    pairs.extend((rng.getrandbits(32), rng.getrandbits(32)) for _ in range(80))
    for index, (a, b) in enumerate(pairs):
        for operation in ("div", "divu", "rem", "remu"):
            dest = ("t2", "t0", "t1")[index % 3] if enabled else "t2"
            emit("li t2, 0x11223344", f"li t0, {a}", f"li t1, {b}",
                 f"{operation} {dest}, t0, t1")
            report(dest, reference(a, b, operation) if enabled else 0x11223344)

    if enabled:
        # 连续除法/余数以及乘除法相互依赖，立即消费前递结果。
        emit("li t0, 987654321", "li t1, 123", "divu t2, t0, t1",
             "remu t2, t2, t1", "mul t2, t2, t1", "divu t2, t2, t1")
        report("t2", (987654321 // 123) % 123)
        emit("li t0, -123456", "li t1, 7", "div t2, t0, t1", "rem t3, t0, t1",
             "mul t4, t2, t3", "addi t4, t4, 1")
        report("t4", 17636 * 4 + 1)

        # load-use 后启动除法；两路源相同、目的与源重叠均覆盖。
        emit("li t0, 0x80000000", "sw t0, 0(s0)", "lw t0, 0(s0)", "div t0, t0, t0")
        report("t0", 1)
        emit("li t0, -1", "lw t1, 0(s0)", "rem t2, t0, t1")
        report("t2", MASK)
        # 商立即作为访存基址，余数立即作为 store 数据。
        emit("li t0, 0x20000", "li t1, 2", "divu t2, t0, t1", "lw t3, 0(t2)")
        report("t3", 0x80000000)

        # 除法到分支/JALR 的前递，以及错误路径上的除法必须被冲刷。
        emit("li t0, 21", "li t1, 3", "li t3, 99", "div t2, t0, t1",
             "beq t2, t3, fail", "bne t2, t3, taken", "div t3, t0, t1", "taken:")
        report("t3", 99)
        emit("la t0, indirect_target", "li t1, 1", "divu t2, t0, t1",
             "jalr zero, 0(t2)", "li t3, 0", "indirect_target:")
        report("t3", 99)
        # 相同循环分支反复预测，取指保持期间不得丢指令或重复执行。
        emit("li s1, 12", "li t0, 500", "li t1, 7", "divide_loop:",
             "divu t2, t0, t1", "addi t0, t0, 13", "addi s1, s1, -1",
             "bne s1, zero, divide_loop")
        report("t2", (500 + 11 * 13) // 7)
        emit("div zero, t0, t1", "addi t2, zero, 5")
        report("t2", 5)
        emit("remu t2, zero, zero")
        report("t2", 0)

    emit("li t0, 1", "sw t0, 0(t6)", "halt: j halt", "fail:", "sw zero, 0(t6)", "j fail")
    base = OUT / f"divide-{enabled}"
    source = base.with_suffix(".S")
    source.write_text("\n".join(lines) + "\n")
    run([PREFIX + "gcc", "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-nostdlib",
         "-nostartfiles", "-T", ROOT / "link.ld", "-o", base.with_suffix(".elf"), source])
    run([PREFIX + "objcopy", "-j", ".text", "-O", "binary", base.with_suffix(".elf"), base.with_suffix(".bin")])
    data = base.with_suffix(".bin").read_bytes()
    base.with_suffix(".hex").write_text("".join(
        f"{int.from_bytes(data[i:i+4], 'little'):08x}\n" for i in range(0, len(data), 4)))
    base.with_suffix(".data").write_text("00\n")
    return base, expected


def simulate(base, enabled):
    # 关闭时完全不提供两个除法器源文件，验证生成条件确实去除了实例。
    names = CPU_NAMES + (["divide_unit", "divider_core"] if enabled else [])
    sim = Path(str(base) + ".out")
    run(["iverilog", "-g2012", "-s", "TB_Acore", "-DNO_WAVES",
         f'-DPROG_FILE="{base.with_suffix(".hex")}"',
         f'-DDATA_FILE="{base.with_suffix(".data")}"',
         f"-PTB_Acore.ENABLE_DIV={enabled}", "-o", sim, ROOT / "Iverilog/TB_Acore.v",
         *[ROOT / f"vsrc/{name}.v" for name in names]])
    try:
        log = run(["vvp", sim])
    except subprocess.CalledProcessError as error:
        Path(str(base) + ".log").write_text(error.stdout)
        raise ValueError(f"仿真失败，日志：{base}.log\n{error.stdout}") from error
    Path(str(base) + ".log").write_text(log)
    if not re.search(r"PASS\s+exit_code=1\b", log):
        raise ValueError("Acore 没有正常退出")
    return [int(x, 16) for x in re.findall(r"\[print\]\s+\d+\s+\(0x([0-9a-fA-F]+)\)", log)]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    unit = OUT / "TB_divider.out"
    run(["iverilog", "-g2012", "-s", "TB_divider", "-o", unit,
         ROOT / "Iverilog/TB_divider.v", ROOT / "vsrc/divide_unit.v", ROOT / "vsrc/divider_core.v"])
    unit_log = run(["vvp", unit])
    (OUT / "unit.log").write_text(unit_log)
    print(unit_log, end="", flush=True)
    for enabled in (0, 1):
        base, expected = build_program(enabled)
        actual = simulate(base, enabled)
        if actual != expected:
            for index, (got, want) in enumerate(zip(actual, expected)):
                if got != want:
                    raise ValueError(f"ENABLE_DIV={enabled} 第 {index} 个结果：got={got:08x}, expected={want:08x}")
            raise ValueError(f"输出数量错误：got={len(actual)}, expected={len(expected)}")
        print(f"PASS: TB_Acore ENABLE_DIV={enabled}，{len(expected)} 个结果匹配", flush=True)

    state, checksum = 0x12345678, 0
    for _ in range(200):
        state = (state * 1664525 + 1013904223) & MASK
        checksum = (checksum + state // ((state >> 24) + 1)) & MASK
    times = {}
    for enabled, isa in ((0, "rv32i_zmmul"), (1, "rv32im")):
        base = OUT / f"benchmark-{enabled}"
        build_log = run(["env", f"ISA={isa}", "KEEP=1", "bash", "build.sh",
                         base.with_suffix(".hex"), base.with_suffix(".data"),
                         "asm/start.s", "csrc/software/div_benchmark.c"])
        Path(str(base) + "-build.log").write_text(build_log)
        values = simulate(base, enabled)
        if len(values) != 2 or values[1] != checksum or not values[0]:
            raise ValueError(f"除法基准校验失败：{values}, checksum={checksum}")
        times[enabled] = values[0]
        print(f"PASS: 除法基准 ENABLE_DIV={enabled}，cycles={values[0]}，checksum=0x{checksum:08x}", flush=True)
    print(f"除法密集程序加速比：{times[0] / times[1]:.3f} 倍", flush=True)


if __name__ == "__main__":
    main()
