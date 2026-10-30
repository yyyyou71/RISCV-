"""Short board integration test with deliberately clockless/in-reset PCIe IP."""
from pathlib import Path
import hashlib,json,subprocess
from lint_video_platform import ports
ROOT=Path(__file__).resolve().parents[1]


def main():
    out=ROOT/'build/standalone-capture';out.mkdir(parents=True,exist_ok=True)
    stubs=[]
    vendor=[ROOT/'ipcore'/n/(n+'.v') for n in ['pcie_test','PLL_CLK','ddr_2_fifo']]
    vendor+=[ROOT/'rtl/pcie/dma/ips2l_pcie_dma_ram/ips2l_pcie_dma_ram.v']
    for p in vendor:
        body=''
        if p.stem=='pcie_test':body='assign pclk=0;assign pclk_div2=0;assign ref_clk=0;assign core_rst_n=0;'
        elif p.stem=='ddr_2_fifo':body='assign rd_empty=1;assign almost_empty=1;assign wr_full=0;assign wr_water_level=0;assign rd_data=0;'
        stubs.append(ports(p,p.stem).replace('endmodule',body+'\nendmodule'))
    stub=out/'vendor_stubs.v';stub.write_text('\n'.join(stubs))
    exclude={'memory_core.v','ROM_core.v','multiplier_core.v','acore_fetch_memory.v',
             'multiply_adder.v','multiply_adder_w8a16.v','video_async_fifo.v','MuxKeyInternal.v'}
    sources=[p for p in sorted((ROOT/'rtl').glob('*.v')) if p.name not in exclude]
    for directory,pattern in [('rtl/video','**/*.v'),('rtl/rk_iic','*.v'),('rtl/rk_fspi','*.v'),
                              ('board','*.v'),('sim/models','*.v'),('ipcore/pcie_test/rtl/hsst_pipe','*.v')]:
        sources+=sorted((ROOT/directory).glob(pattern))
    sources+=[p for p in sorted((ROOT/'rtl/pcie/dma').rglob('*.v')) if 'ips2l_pcie_dma_ram' not in p.parts]
    sources+=[ROOT/'sim/ddr3/ddr3.sv',ROOT/'sim/video/fifo_2_ddr_model.v',ROOT/'sim/video/TB_standalone_capture.v',stub]
    binary=out/'obj'/'check'
    cmd=['verilator','--binary','--timing','--assert','-j','4','-Wno-fatal','-Wno-TIMESCALEMOD',
         '--top-module','TB_standalone_capture','--Mdir',str(binary.parent),'-o','check',
         '-DPROG_FILE="firmware/preprocess_bringup/acore_dual_rom.hex"',
         '-DDATA_FILE="firmware/preprocess_bringup/acore_dual_ram_bytes.hex"',
         '-DDDR3_MODEL_SLOTS=8192',*map(str,sources)]
    with (out/'compile.log').open('w') as log:
        r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=180)
    if r.returncode:raise RuntimeError((out/'compile.log').read_text()[-6000:])
    r=subprocess.run([str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=60)
    text=r.stdout+r.stderr;(out/'run.log').write_text(text)
    summary=next((l for l in text.splitlines() if l.startswith('PASS ')),None)
    if r.returncode or not summary:raise RuntimeError(text[-6000:])
    print(summary)
    report=dict(passed=True,scope='clock/reset, CPU startup and disabled reader; no full-frame/AI regression',
                pcie_model='clocks forced zero, core reset forced asserted; vendor PCIe not simulated',
                ddr_model='previously validated behavioral native interface',hardware_tested=False,
                summary=summary,sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                                        for p in sources if p!=stub})
    (ROOT/'reports/preprocess/standalone_reset.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
