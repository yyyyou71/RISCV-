#!/usr/bin/env python3
"""执行真实 CSR/中断程序，检查恢复位置、指令副作用、完整 GPR 现场和停顿。

请求在指定指令处由 TB 提出，并保持到服务程序写 ACK。静态期望恢复 PC
来自 ELF 标签，不使用被测 RTL 自己计算出的地址作为参考。
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/interrupt"
PREFIX = "riscv64-unknown-elf-"


def run(args, log=None):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        Path(log).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}")
    return result.stdout


def check(reg, value):
    return [f"li t6, {value}", f"bne {reg}, t6, fail"]


def finish():
    return ["li t6, 0x30000", "li t0, 1", "sw t0, 0(t6)", "halt: j halt",
            "fail:", "li t6, 0x30000", "li t0, 0xbad", "sw t0, 0(t6)", "j fail"]


def handler():
    lines = [".globl trap_handler", "trap_handler:",
             "csrr t0, mcause", "li t1, 0x80000007", "bne t0, t1, fail",
             "csrr t0, mstatus", "andi t0, t0, 0x88", "li t1, 0x80", "bne t0, t1, fail",
             "li t0, 0x30010", "sw zero, 0(t0)"]
    # 故意破坏除 sp/ra 外的全部 GPR，检查公共入口确实负责保存、恢复。
    lines += [f"li x{reg}, {0xcafe0000 + reg}" for reg in range(3, 32)]
    return lines + ["ret"]


def asm_program(body, enable=True):
    lines = [".text", ".globl _start", "_start:", "la sp, _stack_top"]
    lines += [f"li x{reg}, {0x102000 + reg}" for reg in range(3, 32)]
    lines += ["li s0, 0x10000", "li t6, 0x30000", "la t0, trap_entry", "csrw mtvec, t0",
              "li t0, 0x80", "csrw mie, t0"]
    if enable:
        lines += ["csrsi mstatus, 8"]
    return "\n".join(lines + body + finish() + handler()) + "\n"


def build(name, source, c_demo=False):
    base = OUT / name
    base.with_suffix(".S").write_text(source)
    sources = [base.with_suffix(".S"), ROOT / "asm/trap_entry.S"]
    if c_demo:
        sources += [ROOT / "csrc/software/interrupt_demo.c"]
    run([PREFIX + "gcc", "-march=rv32im", "-mno-div", "-mabi=ilp32", "-mno-relax",
         "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-nostdlib", "-nostartfiles",
         "-O1", "-T", ROOT / "firmware/link.ld", "-o", base.with_suffix(".elf"), *sources],
        base.with_suffix(".build.log"))
    base.with_suffix(".dis").write_text(run([PREFIX + "objdump", "-d", base.with_suffix(".elf")]))
    symbols = {}
    for line in run([PREFIX + "nm", "-n", base.with_suffix(".elf")]).splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    for section, suffix, width in ((".text", ".hex", 4), (".data", ".data", 1)):
        binary = Path(str(base) + section + ".bin")
        run([PREFIX + "objcopy", "-j", section, "-O", "binary", base.with_suffix(".elf"), binary])
        data = binary.read_bytes()
        base.with_suffix(suffix).write_text("".join(
            f"{int.from_bytes(data[i:i+width], 'little'):0{width*2}x}\n"
            for i in range(0, len(data), width)) or "00\n")
    return base, symbols


def simulate(name, source, inject="inject", resume="resume", enabled=0,
             skip=0, stalled=0, min_wait=0, irqs=1, c_demo=False,
             stores=0, prediction=-1, taken=-1):
    base, symbols = build(name, source, c_demo)
    sim = base.with_suffix(".out")
    run(["iverilog", "-g2012", "-s", "TB_interrupt", "-y", ROOT / "sim/models", "-y", ROOT / "rtl",
         f'-DPROG_FILE="{base.with_suffix(".hex")}"',
         f'-DDATA_FILE="{base.with_suffix(".data")}"',
         f"-PTB_interrupt.ENABLE_DIV={enabled}", "-o", sim, ROOT / "sim/TB_interrupt.v"],
        base.with_suffix(".compile.log"))
    args = ["vvp", sim, f"+irqs={irqs}", f"+skip={skip}", f"+stall={stalled}", f"+min_wait={min_wait}",
            f"+stores={stores}", f"+prediction={prediction}", f"+taken={taken}"]
    if irqs:
        args += [f"+inject={symbols[inject]:x}", f"+resume={symbols[resume]:x}"]
    report = run(args, base.with_suffix(".run.log"))
    if "PASS interrupt" not in report:
        raise RuntimeError(f"No completion for {name}: {report}")
    summary = re.search(r"^PASS interrupt.*$", report, re.MULTILINE).group(0)
    print(f"{name}: {summary}", flush=True)


def csr_program():
    b = ["csrr t0, mstatus"] + check("t0", 0x1800)
    b += ["csrrwi t0, mstatus, 0"] + check("t0", 0x1800)
    b += ["csrrsi t0, mstatus, 8", "csrr t1, mstatus"] + check("t0", 0x1800) + check("t1", 0x1808)
    b += ["csrrci t0, mstatus, 8", "csrr t1, mstatus"] + check("t0", 0x1808) + check("t1", 0x1800)
    b += ["li t1, 0x100", "csrrw t0, mepc, t1"] + check("t0", 0)
    b += ["li t3, 0x200", "csrrs t2, mepc, t3", "csrr t0, mepc"] + check("t2", 0x100) + check("t0", 0x300)
    b += ["csrrc t4, mepc, t3", "csrr t0, mepc"] + check("t4", 0x300) + check("t0", 0x100)
    # x0 源的 RS/RC 只读；RW 则必须写零。rd=x0 不得丢掉实际写入。
    b += ["csrrs zero, mepc, zero", "csrrc zero, mepc, zero", "csrr t0, mepc"] + check("t0", 0x100)
    b += ["csrrw zero, mepc, zero", "csrr t0, mepc"] + check("t0", 0)
    b += ["csrrwi zero, mepc, 31", "csrrsi t0, mepc, 0", "csrrci t1, mepc, 0"] + check("t0", 28) + check("t1", 28)
    b += ["li t2, 0", "csrrs t0, mepc, t2", "csrr t1, mepc"] + check("t0", 28) + check("t1", 28)
    # load -> CSR 冒险、CSR -> 算术 -> CSR 前递、连续访问同一个 CSR。
    b += ["li t0, 0x340", "sw t0, 0(s0)", "lw t1, 0(s0)", "csrw mepc, t1",
          "csrr t0, mepc", "addi t1, t0, 4", "csrw mtvec, t1", "csrr t2, mtvec"] + check("t2", 0x344)
    b += ["li t0, 0xffffffff", "csrw mie, t0", "csrr t1, mie"] + check("t1", 0x80)
    b += ["csrr t1, mip"] + check("t1", 0)
    b += ["jal zero, skip_csr", "csrw mie, zero", "skip_csr:", "csrr t1, mie"] + check("t1", 0x80)
    # 软件写原因和返回地址均可读回；mepc/mtvec 的模式与对齐规则生效。
    b += ["li t0, 0x80000007", "csrw mcause, t0", "csrr t1, mcause"] + check("t1", 0x80000007)
    return asm_program(b, enable=False)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    simulate("csr-instructions", csr_program(), irqs=0)

    b = ["li s1, 7", "li s2, 9", "inject: addi s1, s1, 1", "resume: addi s2, s2, 5"]
    simulate("ordinary", asm_program(b + check("s1", 8) + check("s2", 14)))

    b = ["li t0, 0x55", "inject: sw t0, 20(t6)", "resume: sw t0, 24(t6)"]
    simulate("mmio-store", asm_program(b), stores=1)

    b = ["li t0, 123", "sw t0, 0(s0)", "inject: lw s1, 0(s0)", "resume: addi s2, s1, 1"]
    simulate("load-completes", asm_program(b + check("s1", 123) + check("s2", 124)))

    b = ["li t0, 123", "sw t0, 0(s0)", "lw s1, 0(s0)",
         "inject: addi s2, s1, 1", "resume: addi s3, s2, 1"]
    simulate("load-use-wait", asm_program(b + check("s2", 124) + check("s3", 125)), stalled=1, min_wait=1)

    for enabled, operation, expected, minimum in ((0, "mul", 123 * 7, 2), (1, "divu", 123 // 7, 30)):
        b = ["li t0, 123", "li t1, 7", f"inject: {operation} s1, t0, t1", "resume: addi s2, s1, 1"]
        simulate(f"{operation}-wait", asm_program(b + check("s1", expected) + check("s2", expected + 1)),
                 enabled=enabled, stalled=1, min_wait=minimum)

    # 当前 EX 指令同一个分支：冷预测 taken、训练后 taken、训练后实际 not-taken。
    for name, skip, resume in (("branch-cold-taken", 0, "loop"),
                               ("branch-predicted-taken", 2, "loop"),
                               ("branch-wrong-not-taken", 4, "resume")):
        b = ["li s1, 5", "loop: addi s1, s1, -1", "inject: bne s1, zero, loop", "resume: nop"]
        simulate(name, asm_program(b + check("s1", 0)), skip=skip, resume=resume,
                 prediction=int(skip == 2), taken=int(skip != 4))

    b = ["li s1, 1", "inject: beq s1, zero, fail", "resume: addi s1, s1, 1"]
    simulate("branch-correct-not-taken", asm_program(b + check("s1", 2)), prediction=1, taken=0)

    # 被取消的 IF/ID 指令自身是分支：返回它的 PC，之后再执行它。
    b = ["li s1, 1", "inject: addi s1, s1, 1", "resume: beq s1, zero, fail"]
    simulate("younger-branch", asm_program(b + check("s1", 2)))

    b = ["inject: jal s3, resume", "wrong_path: j fail", "resume:",
         "la t0, wrong_path", "bne s3, t0, fail"]
    simulate("jal-link", asm_program(b))

    b = ["la s2, first_target", "inject: jalr s3, 0(s2)", "link_address: j fail",
         "first_target: la s2, resume", "j inject", "resume:",
         "la t0, link_address", "bne s3, t0, fail"]
    simulate("jalr-wrong-target", asm_program(b), skip=1, prediction=0, taken=1)

    # 总开关关闭期间到来的电平请求保持，软件开中断后才正式接受。
    b = ["inject: nop", "csrsi mstatus, 8", "enable_boundary: nop", "resume: nop"]
    simulate("masked-pending", asm_program(b, enable=False), min_wait=2)

    c_start = "\n".join([".text", ".globl _start", "_start:", "la sp, _stack_top",
                          "call main", "li t0, 0x30000", "sw a0, 0(t0)", "1: j 1b"]) + "\n"
    # 标签上的 NOP 继续完成，恢复位置是下一条指令。
    base, symbols = build("c-handler", c_start, c_demo=True)
    # simulate 以符号查询期望值，补一个不会改变程序布局的绝对符号。
    c_start += f".globl c_resume\n.set c_resume, {symbols['interrupt_demo_wait'] + 4}\n"
    simulate("c-handler", c_start, inject="interrupt_demo_wait", resume="c_resume", c_demo=True)
    print("PASS: all interrupt/CSR firmware cases", flush=True)


if __name__ == "__main__":
    main()
