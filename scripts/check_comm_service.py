"""Short CPU communication check: SPI-only transport, no legacy IIC dependencies."""
from pathlib import Path
import subprocess
import sys

if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    subprocess.run([sys.executable, str(root / "scripts/check_sim.py"),
                    "--test", "TB_cpu_fspi", "--core", "acore_dual"], cwd=root, check=True)
