import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.run([str(argument) for argument in arguments], cwd=ROOT, check=True, **kwargs)


def write_words(path, data, size, padding, verify=False):
    if len(data) > size:
        raise ValueError(f"{path.name} exceeds {size} bytes")
    data += bytes((-len(data)) % 4)
    words = [int.from_bytes(data[offset:offset + 4], "little")
             for offset in range(0, len(data), 4)]
    words += [padding] * (size // 4 - len(words))
    content = "".join(f"{word:08x}\n" for word in words)
    if verify:
        if not path.is_file() or path.read_text(encoding="ascii") != content:
            raise ValueError(f"Rebuilt image differs: {path}")
    else:
        path.write_text(content, encoding="ascii")


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
    parser.add_argument("--application", "--app", choices=("coremark", "selftest", "iic_service", "fspi_service", "video_bringup", "preprocess_bringup", "video_diagnostic"), default="coremark")
    parser.add_argument("--core", choices=("single", "acore_dual"), default="single")
    parser.add_argument("--verify-existing", action="store_true")
    parser.add_argument("--mode", choices=("performance", "validation"), default="performance")
    parser.add_argument("--iterations", type=int)
    parser.add_argument('--image-dir', type=Path, default=ROOT / 'firmware')
    args = parser.parse_args()
    args.image_dir.mkdir(parents=True, exist_ok=True)
    if args.iterations is None:
        args.iterations = 2700 if args.core == "acore_dual" else 1000
    if not 1 <= args.iterations <= 8000:
        parser.error("iterations must be in [1, 8000]; keep timing below the 32-bit counter wrap")
    output = ROOT / "build/firmware" / (args.application + f"-{args.mode}-{args.iterations}")
    if args.core == "acore_dual":
        output = output.parent / ("acore-dual-" + output.name)
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
        if args.core == "acore_dual":
            options.append("-DCOREMARK_ACORE_DUAL=1")
        linker = port / "link.ld"
    else:
        sources = [ROOT / "firmware/start.S", ROOT / "firmware" / (args.application + ".c")]
        linker = ROOT / "firmware/link.ld"
        options = []
        if args.application in ("fspi_service", "video_diagnostic"):
            sources.append(ROOT / "firmware" / ("rk_spi_comm.c" if args.application == "video_diagnostic" else "rk_comm.c"))
            options += ["-Wall", "-Wextra", "-Werror"]
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
    prefix = "" if args.core == "single" else args.core + "_"
    ram_size = 65536
    for section, size, padding, name in [
            (".text", 32768, 0x00000013, prefix + "rom.hex"), (".data", ram_size, 0, prefix + "ram.hex")]:
        binary = output / (section[1:] + ".bin")
        run([args.prefix + "objcopy", "-j", section, "-O", "binary", elf, binary])
        write_words(args.image_dir / name, binary.read_bytes(), size, padding, args.verify_existing)
    initialized = (output / "data.bin").read_bytes()
    if args.core in ("single", "acore_dual"):
        byte_image = "".join(f"{value:02x}\n" for value in initialized.ljust(ram_size, b"\0"))
        if args.verify_existing:
            if (args.image_dir / (prefix + "ram_bytes.hex")).read_text(encoding="ascii") != byte_image:
                raise ValueError("Rebuilt byte image differs")
        else:
            (args.image_dir / (prefix + "ram_bytes.hex")).write_text(byte_image, encoding="ascii")
    dependencies = sources + [linker]
    if args.application in ("iic_service", "fspi_service"):
        dependencies += [ROOT / "firmware/rk_link.h"]
    if args.application in ("fspi_service", "video_diagnostic"):
        dependencies += [ROOT / "firmware/rk_comm.h",
                         ROOT / "csrc/rk_fspi/fspi_v2.h",
                         ROOT / "csrc/rk_fspi/comm_protocol.h"]
    if args.application in ("preprocess_bringup", "video_diagnostic"):
        dependencies += [ROOT / "firmware/preprocess_capture.h"]
    if args.application == "coremark":
        dependencies += [ROOT / "csrc/coremark_port/platform.h", ROOT / "csrc/coremark_port/core_portme.h"]
    manifest = {"application": args.application, "mode": args.mode, "iterations": args.iterations,
                "core": args.core, "isa": "rv32i_zmmul", "enable_div": 0,
                "mul_pipeline_stages": 3,
                "clock_hz": 25000000, "baud_rate": 115200, "flags": flags + defines,
                "compiler": subprocess.check_output([args.prefix + "gcc", "--version"], text=True).splitlines()[0],
                "elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest(),
                "rom_sha256": hashlib.sha256((args.image_dir / (prefix + "rom.hex")).read_bytes()).hexdigest(),
                "ram_sha256": hashlib.sha256((args.image_dir / (prefix + "ram.hex")).read_bytes()).hexdigest(),
                "sources": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in dependencies}}
    manifest_name = "manifest.json" if args.core == "single" else "manifest_" + args.core + ".json"
    manifest_paths = [output / "manifest.json", args.image_dir / "manifest.json"]
    if args.image_dir.resolve() == (ROOT / "firmware").resolve():
        manifest_paths.append(ROOT / "build/firmware" / manifest_name)
    for path in manifest_paths:
        path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
