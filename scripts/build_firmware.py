import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(arguments):
    subprocess.run([str(argument) for argument in arguments], cwd=ROOT, check=True)


def write_words(path, data, size, padding):
    if len(data) > size:
        raise ValueError(f"{path.name} exceeds {size} bytes")
    data += bytes((-len(data)) % 4)
    words = [int.from_bytes(data[offset:offset + 4], "little")
             for offset in range(0, len(data), 4)]
    words += [padding] * (size // 4 - len(words))
    path.write_text("".join(f"{word:08x}\n" for word in words), encoding="ascii")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", default="riscv64-unknown-elf-")
    args = parser.parse_args()
    output = ROOT / "build/firmware"
    output.mkdir(parents=True, exist_ok=True)
    elf = output / "selftest.elf"
    flags = ["-march=rv32i", "-mabi=ilp32", "-O2", "-mno-relax",
             "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin",
             "-fno-common", "-fno-stack-protector", "-nostdlib", "-nostartfiles"]
    run([args.prefix + "gcc", *flags, "-T", ROOT / "firmware/link.ld",
         "-Wl,-Map=" + str(output / "selftest.map"), "-o", elf,
         ROOT / "firmware/start.S", ROOT / "firmware/selftest.c", "-lgcc"])
    run([args.prefix + "size", elf])
    for section, size, padding, name in [
            (".text", 32768, 0x00000013, "rom.hex"),
            (".data", 65536, 0, "ram.hex")]:
        binary = output / (section[1:] + ".bin")
        run([args.prefix + "objcopy", "-j", section, "-O", "binary", elf, binary])
        write_words(ROOT / "firmware" / name, binary.read_bytes(), size, padding)
    initialized = (output / "data.bin").read_bytes()
    (ROOT / "firmware/ram_bytes.hex").write_text(
        "".join(f"{value:02x}\n" for value in initialized.ljust(65536, b"\0")),
        encoding="ascii")
    manifest = {"application": "selftest", "clock_hz": 25000000, "baud_rate": 115200,
                "rom_sha256": hashlib.sha256((ROOT / "firmware/rom.hex").read_bytes()).hexdigest(),
                "ram_sha256": hashlib.sha256((ROOT / "firmware/ram.hex").read_bytes()).hexdigest()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
