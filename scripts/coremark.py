#!/usr/bin/env python3
"""Build RV32I CoreMark, run Icarus/Verilator, and verify the benchmark report."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PORT = ROOT / "csrc/coremark_port"
UPSTREAM = ROOT / "third_party/coremark"
CLOCK_HZ = 50_000_000  # TB_Acore: 1 ns time unit, #10 half period
PREFIX = "riscv64-unknown-elf-"
# 2000-byte, single-context reference values from upstream core_main.c.
EXPECTED = {
    "performance": (0xe9f5, 0xe714, 0x1fd7, 0x8e3a),
    "validation": (0x18f2, 0xe3c1, 0x0747, 0x8d84),
}
SHORT_RUN_ERROR = "ERROR! Must execute for at least 10 secs for a valid result!"


def command(args, **kwargs):
    return subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kwargs)


def check_sources():
    for line in (UPSTREAM / "coremark.md5").read_text().splitlines():
        expected, name = line.split()
        actual = hashlib.md5((UPSTREAM / name).read_bytes()).hexdigest()
        # Upstream commit 1f483d5 has an outdated coremark.h entry in coremark.md5.
        # Accept only its exact checked-in header, not arbitrary modifications.
        if name == "coremark.h" and actual == "b0ec69b6c8e75853d06accb3b1bcf534":
            continue
        if actual != expected:
            raise ValueError(f"Upstream source checksum mismatch: {name}")


def build(mode, iterations, sources, simulator="iverilog", isa="rv32i"):
    base = ROOT / "build/coremark"
    # 按 ISA 隔离结果，保留原有 RV32I 基线目录。
    if isa != "rv32i":
        base /= isa
    if simulator == "verilator":
        base /= "verilator"
    out = base / f"{mode}-{iterations}"
    out.mkdir(parents=True, exist_ok=True)
    # A new binary must not retain the previous binary's success metadata.
    (out / "result.json").unlink(missing_ok=True)
    elf = out / "coremark.elf"
    # 兼容本机 GCC 10：允许硬件乘法，除法仍走 RV32I 软件库。
    isa_flags = ["-march=rv32im", "-mno-div"] if isa == "rv32i_zmmul" else ["-march=rv32i"]
    flags = [*isa_flags, "-mabi=ilp32", "-O2", "-msmall-data-limit=0",
             "-mno-relax", "-ffreestanding", "-fno-builtin", "-fno-common",
             "-fno-stack-protector", "-fno-pic", "-fno-pie",
             "-nostdlib", "-nostartfiles"]
    defines = [f"-DITERATIONS={iterations}", "-DTOTAL_DATA_SIZE=2000",
               f"-D{mode.upper()}_RUN=1", f"-DCPU_CLOCK_HZ={CLOCK_HZ}"]
    reported_flags = " ".join(flags + defines)
    libgcc = subprocess.check_output(
        [PREFIX + "gcc", "-march=rv32i", "-mabi=ilp32", "-print-libgcc-file-name"],
        text=True).strip()
    command([PREFIX + "gcc", *flags, *defines,
             f'-DFLAGS_STR="{reported_flags}"', "-I", PORT, "-I", UPSTREAM,
             "-T", PORT / "link.ld", f"-Wl,-Map={out / 'coremark.map'}",
             "-o", elf, *sources, libgcc])
    command([PREFIX + "size", elf])
    with (out / "coremark.dis").open("w") as stream:
        command([PREFIX + "objdump", "-d", elf], stdout=stream)
    # 检查最终程序（包括库代码），避免只检查 C 编译参数而漏掉库中除法。
    disassembly = (out / "coremark.dis").read_text()
    if re.search(r"\t(?:divu?|remu?)\s", disassembly):
        raise ValueError("程序包含当前处理器不支持的硬件除法/余数指令")
    if isa == "rv32i_zmmul" and not re.search(r"\tmul(?:h(?:su|u)?)?\s", disassembly):
        raise ValueError("启用乘法扩展后，程序中没有生成硬件乘法指令")
    for section, suffix, width in [(".text", "hex", 4), (".data", "data", 1)]:
        binary = out / f"{section[1:]}.bin"
        command([PREFIX + "objcopy", "-j", section, "-O", "binary", elf, binary])
        data = binary.read_bytes()
        if width == 4:
            data += bytes((-len(data)) % 4)
        lines = [f"{int.from_bytes(data[i:i+width], 'little'):0{width * 2}x}\n"
                 for i in range(0, len(data), width)]
        (out / f"coremark.{suffix}").write_text("".join(lines))
    print(f"Built: {out.relative_to(ROOT)}/coremark.elf", flush=True)
    return out


def field(report, pattern, base=10):
    matches = re.findall(pattern, report, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"Missing or duplicate report field: {pattern}")
    return int(matches[0], base)


def check_report(report, mode, iterations):
    crc_names = ["seedcrc", r"\[0\]crclist", r"\[0\]crcmatrix", r"\[0\]crcstate"]
    crcs = tuple(field(report, rf"^{name}\s*:\s*0x([0-9a-fA-F]+)\s*$", 16)
                 for name in crc_names)
    if crcs != EXPECTED[mode]:
        raise ValueError(f"CRC mismatch: got {crcs}, expected {EXPECTED[mode]}")
    ticks = field(report, r"^Total ticks\s*:\s*(\d+)\s*$")
    actual_iterations = field(report, r"^Iterations\s*:\s*(\d+)\s*$")
    size = field(report, r"^CoreMark Size\s*:\s*(\d+)\s*$")
    final_crc = field(report, r"^\[0\]crcfinal\s*:\s*0x([0-9a-fA-F]+)\s*$", 16)
    if not ticks or actual_iterations != iterations or size != 666:
        raise ValueError("Invalid timing, iteration count or data size")
    # 核验 CPU 软件浮点及 %f 输出，避免 CRC 正确但成绩格式化错误。
    for name, expected in [("Total time (secs)", ticks / CLOCK_HZ),
                           ("Iterations/Sec", iterations * CLOCK_HZ / ticks)]:
        values = re.findall(rf"^{re.escape(name)}\s*:\s*(\d+\.\d+)\s*$",
                            report, re.MULTILINE)
        if len(values) != 1 or not math.isclose(float(values[0]), expected,
                                               rel_tol=1e-9, abs_tol=1e-6):
            raise ValueError(f"Incorrect floating-point report: {name}")
    if "Cannot validate" in report:
        raise ValueError("CoreMark could not validate its results")
    errors = [line for line in report.splitlines() if "ERROR" in line]
    short = ticks < 10 * CLOCK_HZ
    if short:
        if errors != [SHORT_RUN_ERROR] or "Errors detected" not in report:
            raise ValueError("Unexpected CoreMark diagnostics in short run")
    elif errors or "Errors detected" in report or "Correct operation validated." not in report:
        raise ValueError("CoreMark reported validation errors")
    if not re.search(r"^ PASS\s+exit_code=0\b", report, re.MULTILINE):
        raise ValueError("No successful simulation completion")
    result = {"mode": mode, "iterations": iterations, "cycles": ticks,
              "clock_hz": CLOCK_HZ, "seconds": ticks / CLOCK_HZ,
              "crc_pass": True, "crcfinal": f"0x{final_crc:04x}",
              "short_run": short,
              "iterations_per_second": iterations * CLOCK_HZ / ticks,
              "iterations_per_mhz": iterations * 1_000_000 / ticks}
    print(f"\n[{mode}] CRC PASS; {iterations} iteration(s), {ticks} measured cycles", flush=True)
    if mode == "performance":
        label = "SHORT-RUN ESTIMATE (not an official score)" if short else "Performance"
        print(f"{label}: {result['iterations_per_second']:.6f} iterations/s, "
              f"{result['iterations_per_mhz']:.6f} CoreMark/MHz")
    if short:
        print("CRC passed; the upstream <10 seconds warning is expected for this short run.")
    return result


def simulate(out, mode, iterations, max_cycles, simulator="iverilog", isa="rv32i"):
    common = ["-DNO_WAVES", f'-DPROG_FILE="{out / "coremark.hex"}"',
              f'-DDATA_FILE="{out / "coremark.data"}"']
    # 仅编译现有 Acore 测试台和处理器依赖，不解析无关的 SoC。
    names = ["Acore", "PC", "ROM", "ROM_core", "decoder", "ALU", "multiply_unit",
             "multiplier_core", "memory", "memory_core", "GPR_matrix", "Reg",
             "hazard_detection_unit", "branch_predictor"]
    rtl = [ROOT / "Iverilog/TB_Acore.v", *[ROOT / f"vsrc/{name}.v" for name in names]]
    if simulator == "iverilog":
        sim = out / "TB_Acore.out"
        command(["iverilog", "-g2012", "-s", "TB_Acore", *common,
                 "-PTB_Acore.EXPECT_EXIT=0", f"-PTB_Acore.MAX_CYCLES={max_cycles}",
                 "-o", sim, *rtl])
        run_command = ["vvp", "-i", str(sim)]
    else:
        model = out / "obj_dir"
        build_log = out / "verilator-build.log"
        print(f"Compiling Verilator model; log: {build_log.relative_to(ROOT)}", flush=True)
        with build_log.open("w") as log:
            try:
                command(["verilator", "--binary", "--timing", "--assert",
                         "--top-module", "TB_Acore", "-j", "4",
                         "-O3", "-CFLAGS", "-O3", "--Mdir", model,
                         "-o", "coremark_sim", *common, "-GEXPECT_EXIT=0",
                         f"-GMAX_CYCLES=64'd{max_cycles}", *rtl],
                        stdout=log, stderr=subprocess.STDOUT)
            except subprocess.CalledProcessError:
                print(build_log.read_text()[-8000:], file=sys.stderr)
                raise
        run_command = [str(model / "coremark_sim")]
    print(f"Running {mode} on {simulator}, watchdog={max_cycles} cycles "
          "(waveforms disabled)...", flush=True)
    report_lines = []
    started = time.perf_counter()
    with (out / "run.log").open("w") as log:
        with subprocess.Popen(run_command, cwd=ROOT, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True) as proc:
            for line in proc.stdout:
                print(line, end="", flush=True)
                log.write(line)
                log.flush()
                report_lines.append(line)
            if proc.wait():
                raise ValueError(f"Simulation failed; see {out / 'run.log'}")
    elapsed = time.perf_counter() - started
    result = check_report("".join(report_lines), mode, iterations)
    result.update(simulator=simulator, isa=isa, simulation_wall_seconds=elapsed)
    print(f"Host simulation time (excluding build): {elapsed:.3f} s", flush=True)
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "run"])
    parser.add_argument("--mode", choices=["both", "performance", "validation"], default="both")
    parser.add_argument("--simulator", choices=["iverilog", "verilator"], default="iverilog")
    parser.add_argument("--isa", choices=["rv32i", "rv32i_zmmul"], default="rv32i")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--max-cycles", type=int, default=20_000_000)
    parser.add_argument("--sources", nargs="+", required=True)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 0x7fffffff:
        parser.error("iterations must be positive (automatic calibration is disabled)")
    if not 1 <= args.max_cycles < 2**32:
        parser.error("max-cycles must be in [1, 2^32), because the timer is 32-bit")
    check_sources()
    modes = EXPECTED if args.mode == "both" else [args.mode]
    for mode in modes:
        out = build(mode, args.iterations, args.sources, args.simulator, args.isa)
        if args.action == "run":
            simulate(out, mode, args.iterations, args.max_cycles, args.simulator, args.isa)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"CoreMark failed: {error}", file=sys.stderr)
        sys.exit(1)
