"""Run portable DDR3 model regression from the repository root (Linux/Windows)."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(command, log, expected_failure=None):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True,
                            text=True, errors="replace", timeout=180)
    report = result.stdout + result.stderr
    log.write_text(report, encoding="utf-8")
    if expected_failure:
        if result.returncode == 0 or expected_failure not in report:
            raise RuntimeError(f"Expected rejection missing: {log}\n{report[-3000:]}")
    elif result.returncode or "FATAL" in report or "ERROR" in report:
        raise RuntimeError(f"Failed (exit {result.returncode}): {log}\n{report[-4000:]}")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    args = parser.parse_args()
    output = ROOT / "build/ddr3/iverilog"
    output.mkdir(parents=True, exist_ok=True)
    executable = output / "tb_ddr3.vvp"
    run([args.iverilog, "-g2012", "-s", "tb_ddr3", "-o", executable,
         ROOT / "sim/ddr3/ddr3.sv", ROOT / "sim/ddr3/tb_ddr3.sv"], output / "compile.log")
    cases = {
        "default": [],
        "stalls": ["+ddr3_stall_every=7", "+ddr3_stall_cycles=3"],
        "random": ["+ddr3_random_stalls=1", "+ddr3_seed=12345"],
        "zero_latency": ["+ddr3_read_latency=0", "+ddr3_write_latency=0"],
        "slow": ["+ddr3_read_latency=19", "+ddr3_write_latency=11",
                 "+ddr3_random_stalls=1", "+ddr3_seed=97"],
        "zero_init": ["+ddr3_zero_init=1"],
    }
    for name, switches in cases.items():
        report = run([args.vvp, executable, *switches], output / f"{name}.log")
        if "PASS tb_ddr3" not in report:
            raise RuntimeError(f"Missing PASS in {name}")
        print(name, report.strip(), flush=True)
    for name, message in (("unaligned", "BL8 aligned"),
                          ("unstable_aw", "AW changed/withdrawn")):
        run([args.vvp, executable, f"+test_{name}"], output / f"reject_{name}.log", message)
        print(f"PASS expected rejection: {name}", flush=True)
    sparse = output / "tb_sparse.vvp"
    run([args.iverilog, "-g2012", "-DDDR3_MODEL_SLOTS=4", "-s", "tb_ddr3", "-o", sparse,
         ROOT / "sim/ddr3/ddr3.sv", ROOT / "sim/ddr3/tb_ddr3.sv"], output / "sparse_compile.log")
    report = run([args.vvp, sparse, "+test_sparse"], output / "sparse.log")
    if "PASS tb_ddr3 sparse" not in report:
        raise RuntimeError("Sparse storage test did not complete")
    print(report.strip(), flush=True)
    run([args.vvp, sparse, "+test_full"], output / "reject_full.log", "sparse table full")
    print("PASS expected rejection: sparse table full", flush=True)


if __name__ == "__main__":
    main()
