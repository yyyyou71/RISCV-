"""Short SPI-image data/control checks. Run in WSL from the repository root.

Uses behavioral DDR/FIFO models; does not claim physical SPI/PCIe or model
accuracy verification. Does not run the 99-task network or start a PDS flow.
"""
from pathlib import Path
import hashlib,json,subprocess,time

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/spi-image'
COMMON=['rtl/video/spi_image_capture.v','rtl/ddr_block_transfer.v',
        'rtl/video/preprocess/rgb888_pool96_stream.v','rtl/video/preprocess/pool_sum_ram.v',
        'sim/models/pango_pool_sum_ram.v','sim/video/fifo_2_ddr_model.v',
        'sim/video/spi_tensor_fifo_model.v']
CASES={
    'TB_spi_image':COMMON+['sim/video/TB_spi_image.v'],
    'TB_spi_image_pcie':COMMON+['rtl/video/frame_ring_ddr3.v','rtl/video/ddr3_read_ctrl.v',
        'rtl/video/rgb565_box_overlay.v','rtl/ddr_native_arbiter.v','rtl/ddr_region_check.v',
        'sim/ddr3/ddr3.sv','sim/models/pango_video_fifo_model.v','sim/video/TB_spi_image_pcie.v'],
}

def run(args,log,cwd=ROOT,timeout=90):
    start=time.monotonic()
    result=subprocess.run(args,cwd=cwd,capture_output=True,text=True,timeout=timeout)
    output=result.stdout+result.stderr
    (OUT/log).write_text(output)
    if result.returncode:raise RuntimeError(output[-4000:])
    return output,time.monotonic()-start

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    cases=[]
    for top,sources in CASES.items():
        binary=OUT/(top+'.vvp')
        run(['iverilog','-g2012','-s',top,'-o',str(binary),*sources],top+'_compile.log')
        output,seconds=run(['vvp',str(binary)],top+'.log')
        passed=[line for line in output.splitlines() if line.startswith('PASS ')]
        if not passed:raise RuntimeError(output)
        for line in passed:print(line,flush=True)
        cases.append(dict(test=top,passed=True,seconds=seconds,summary=passed))
    output,seconds=run(['make','all','test'],'host_tests.log',ROOT/'csrc/rk_fspi')
    cases.append(dict(test='RK clients + actual firmware C service',passed=True,seconds=seconds,
                      summary=[line for line in output.splitlines() if line.startswith('PASS')]))
    sources=sorted(set(sum(CASES.values(),[])))
    report=dict(passed=True,physical_hardware_verified=False,full_model_regression_run=False,
                cases=cases,sources={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources})
    destination=ROOT/'reports/spi_image';destination.mkdir(parents=True,exist_ok=True)
    (destination/'short_checks.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS short SPI image checks; physical board validation remains separate')

if __name__=='__main__':main()
