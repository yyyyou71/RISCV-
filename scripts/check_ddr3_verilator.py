"""Compile and run an untimed C++ DDR3 regression on Verilator >= 4.038."""
import argparse
from pathlib import Path
from check_ddr3 import ROOT, run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verilator", default="verilator")
    args = parser.parse_args()
    output = ROOT / "build/ddr3/verilator"
    output.mkdir(parents=True, exist_ok=True)
    run([args.verilator, "--cc", "--exe", "--build", "-j", "2", "--top-module", "ddr3",
         "-DDDR3_MODEL_EXTERNAL_CORE_CLOCK", "-Wno-fatal", "--Mdir", output,
         ROOT / "sim/ddr3/ddr3.sv", ROOT / "sim/ddr3/verilator_main.cpp"], output / "compile.log")
    for name, options in {
        "default": [],
        "stalls": ["+ddr3_stall_every=7", "+ddr3_stall_cycles=3"],
        "random": ["+ddr3_random_stalls=1", "+ddr3_seed=12345"],
        "zero_latency": ["+ddr3_read_latency=0", "+ddr3_write_latency=0"],
    }.items():
        report = run([output / "Vddr3", *options], output / f"{name}.log")
        if "PASS verilator_ddr3" not in report:
            raise RuntimeError(f"Missing PASS: {name}")
        print(name, report.strip(), flush=True)


if __name__ == "__main__":
    main()
