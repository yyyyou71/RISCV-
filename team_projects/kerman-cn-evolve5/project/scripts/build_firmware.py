"""Build one bare-metal C application without starting the simulator."""
import argparse
import os
from pathlib import Path
from soc_regress import PROJECT,arithmetic_header,build_firmware

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--app',choices=[x.stem for x in (PROJECT/'firmware'/'apps').glob('*.c')],default='selftest')
    p.add_argument('--opt',choices=['O0','O1','O2','Os'],default='O2')
    p.add_argument('--clock-hz',type=int,default=None)
    p.add_argument('--baud',type=int,default=115200)
    p.add_argument('--gcc',type=Path,default=Path(r'D:\riscv\riscv64-unknown-elf-toolchain-10.2.0-2020.12.8-x86_64-w64-mingw32\bin\riscv64-unknown-elf-gcc.exe'))
    p.add_argument('--build-dir',type=Path,default=PROJECT.parents[1]/'work'/'cache3_soc')
    a=p.parse_args(); a.build_dir.mkdir(parents=True,exist_ok=True)
    arithmetic_header(PROJECT/'firmware'/'generated'/'arithmetic_vectors.h')
    hz=a.clock_hz if a.clock_hz is not None else (25000000 if a.app=='board_demo' else 50000000)
    folder,facts=build_firmware(a.app,a.opt,a.gcc,a.build_dir,os.environ.copy(),clock_hz=hz,baud=a.baud)
    print(f'FIRMWARE_BUILD_PASS {folder}\nROM image: {facts["image_bytes"]} bytes; all executable words checked as RV32I.')

if __name__=='__main__': main()
