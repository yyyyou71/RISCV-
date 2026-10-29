"""Test imported DMA TX RTL only; no PCIe/PHY/vendor IP is instantiated."""
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/sim/pcie'
OUT.mkdir(parents=True, exist_ok=True)
sources = ['sim/pcie/TB_pcie_mwr.v', 'rtl/pcie/pcie_test_source.v',
           'rtl/pcie/dma/ips2l_pcie_dma_mwr_tx_ctrl.v']
subprocess.run(['iverilog', '-g2012', '-s', 'TB_pcie_mwr', '-o',
                str(OUT / 'TB_pcie_mwr.vvp'), *sources], cwd=ROOT, check=True)
result = subprocess.run(['vvp', str(OUT / 'TB_pcie_mwr.vvp')], cwd=ROOT,
                        capture_output=True, text=True)
report = result.stdout + result.stderr
(OUT / 'TB_pcie_mwr.log').write_text(report, encoding='utf-8')
print(report, end='')
if result.returncode or 'PASS:' not in report or 'FATAL' in report or 'ERROR' in report:
    raise RuntimeError('PCIe DMA TX test failed; see build/sim/pcie/TB_pcie_mwr.log')
