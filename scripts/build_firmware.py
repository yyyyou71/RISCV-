import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.run([str(argument) for argument in arguments], cwd=ROOT, check=True, **kwargs)


def write_words(path, data, size, padding):
    if len(data) > size:
        raise ValueError(f"{path.name} exceeds {size} bytes")
    data += bytes((-len(data)) % 4)
    words = [int.from_bytes(data[offset:offset + 4], "little")
             for offset in range(0, len(data), 4)]
    words += [padding] * (size // 4 - len(words))
    path.write_text("".join(f"{word:08x}\n" for word in words), encoding="ascii")


def check_coremark_sources():
    directory = ROOT / "third_party/coremark"
    for line in (directory / "coremark.md5").read_text().splitlines():
        expected, name = line.split()
        actual = hashlib.md5((directory / name).read_bytes()).hexdigest()
        if name == "coremark.h" and actual == "b0ec69b6c8e75853d06accb3b1bcf534":
            continue
        if actual != expected:
            raise ValueError(f"CoreMark upstream source changed: {name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", default="riscv64-unknown-elf-")
    parser.add_argument("--application", choices=("coremark", "selftest"), default="coremark")
    parser.add_argument("--mode", choices=("performance", "validation"), default="performance")
    parser.add_argument("--iterations", type=int, default=1000)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 8000:
        parser.error("iterations must be in [1, 8000]; keep timing below the 32-bit counter wrap")
    output = ROOT / "build/firmware" / (args.application + f"-{args.mode}-{args.iterations}")
    output.mkdir(parents=True, exist_ok=True)
    elf = output / (args.application + ".elf")
    flags = ["-march=rv32im", "-mno-div", "-mabi=ilp32", "-O2", "-mno-relax",
             "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-fno-common",
             "-fno-stack-protector", "-fno-pic", "-fno-pie", "-nostdlib", "-nostartfiles"]
    defines = []
    if args.application == "coremark":
        check_coremark_sources()
        port = ROOT / "csrc/coremark_port"
        sources = [port / "start.S"]
        sources += [ROOT / "third_party/coremark" / name for name in
                    ("core_main.c", "core_list_join.c", "core_matrix.c", "core_state.c", "core_util.c")]
        sources += [port / name for name in ("core_portme.c", "ee_printf.c", "cvt.c")]
        defines = [f"-DITERATIONS={args.iterations}", "-DTOTAL_DATA_SIZE=2000",
                   f"-D{args.mode.upper()}_RUN=1", "-DCPU_CLOCK_HZ=25000000u"]
        options = [*defines, '-DFLAGS_STR="' + " ".join(flags + defines) + '"',
                   "-I", port, "-I", ROOT / "third_party/coremark"]
        linker = port / "link.ld"
    else:
        sources = [ROOT / "firmware/start.S", ROOT / "firmware/selftest.c"]
        linker = ROOT / "firmware/link.ld"
        options = []
    libgcc = subprocess.check_output([args.prefix + "gcc", "-march=rv32i", "-mabi=ilp32",
                                     "-print-libgcc-file-name"], text=True).strip()
    run([args.prefix + "gcc", *flags, *options, "-T", linker,
         "-Wl,-Map=" + str(output / (args.application + ".map")), "-o", elf, *sources, libgcc])
    run([args.prefix + "size", elf])
    disassembly = subprocess.check_output([args.prefix + "objdump", "-d", str(elf)], text=True)
    (output / "firmware.dis").write_text(disassembly)
    if re.search(r"\t(?:divu?|remu?)\s", disassembly):
        raise ValueError("Firmware contains division instructions, but ENABLE_DIV=0")
    if args.application == "coremark" and not re.search(r"\tmul(?:h(?:su|u)?)?\s", disassembly):
        raise ValueError("CoreMark did not generate hardware multiplication instructions")
    for section, size, padding, name in [
            (".text", 32768, 0x00000013, "rom.hex"), (".data", 65536, 0, "ram.hex")]:
        binary = output / (section[1:] + ".bin")
        run([args.prefix + "objcopy", "-j", section, "-O", "binary", elf, binary])
        write_words(ROOT / "firmware" / name, binary.read_bytes(), size, padding)
    initialized = (output / "data.bin").read_bytes()
    (ROOT / "firmware/ram_bytes.hex").write_text(
        "".join(f"{value:02x}\n" for value in initialized.ljust(65536, b"\0")), encoding="ascii")
    manifest = {"application": args.application, "mode": args.mode, "iterations": args.iterations,
                "core": "Acore", "isa": "rv32i_zmmul", "enable_div": 0, "mul_pipeline_stages": 3,
                "clock_hz": 25000000, "baud_rate": 115200, "flags": flags + defines,
                "compiler": subprocess.check_output([args.prefix + "gcc", "--version"], text=True).splitlines()[0],
                "elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest(),
                "rom_sha256": hashlib.sha256((ROOT / "firmware/rom.hex").read_bytes()).hexdigest(),
                "ram_sha256": hashlib.sha256((ROOT / "firmware/ram.hex").read_bytes()).hexdigest(),
                "sources": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in sources + [linker]}}
    for path in (output / "manifest.json", ROOT / "build/firmware/manifest.json"):
        path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
