"""WSL full 96x96 model: CPU DDR staging, actual board/dual core, 99 tasks and CPU postprocess.

HDMI/PCIe PHYs are idle stubs; DDR is the strict behavioral native-interface
model. The W8A16 MAC uses the generated Pango IP and vendor arithmetic primitive.
This is functional simulation, not routed timing or hardware signoff.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import time
from xml.etree import ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'scripts'),str(ROOT/'pc_ai')]
import prepare_trident_network as net
from postprocess_tools import add_real_postprocess,save_cpu_detections
from lint_video_platform import ports


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def preprocess_reference(path):
    """Independent integer average of the 1919-pixel source + one black tail.
    Horizontal bins=20, vertical bins=[floor(y*1080/96), start+12), RNE /240.
    """
    image=bytearray()
    for oy in range(96):
        y0=oy*1080//96
        for ox in range(96):
            for c in range(3):
                total=sum(((y*7+x*3+c*53)&255) if x<1919 else 0
                          for y in range(y0,y0+12) for x in range(ox*20,ox*20+20))
                q,r=divmod(total,240)
                q+=r>120 or (r==120 and q%2==1)
                image.extend(struct.pack('<h',q))
    path.write_bytes(image)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--pds-root',type=Path,required=True)
    p.add_argument('--out',type=Path,default=ROOT/'build/ai-full-board')
    p.add_argument('--jobs',type=int,default=4)
    p.add_argument('--prepare-only',action='store_true')
    p.add_argument('--preprocess',action='store_true',help='Use actual 1919-line padding/preprocessor/vendor FIFOs before AI')
    args=p.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    model=out/'model';ref=args.reference.resolve()
    if args.preprocess:
        source=out/'pooled_reference_hwc.bin';preprocess_reference(source)
        subprocess.run([sys.executable,str(ROOT/'pc_ai/prepare_trident_network.py'),
            '--reference',str(ref),'--out',str(model),'--size','96','--input',str(source),'--golden'],check=True)
    # Generate the full independent C reference if this exact input lacks one.
    current=net.binding(model,ref)
    if not net.golden_status(model,current):raise ValueError('Run prepare_trident_network.py --golden into OUT/model first')
    spec=json.loads((model/'network0.json').read_text());graph=json.loads((model/'graph.json').read_text())
    package=net.pack_model(spec,0x10000,root=model,output_fill=0xa7)
    assets,_=net.audit(package,graph)
    case,info=net.sparse_segment(model,package,graph,assets,0,99,current,'_board')
    sim_args=add_real_postprocess(model,case,info,ref)
    raw=package.data[package.header[8]-package.base:package.header[8]-package.base+package.header[9]]
    if len(raw)!=294912:raise ValueError('Expected 96x96 HWC-align16 INT16 input')
    # Only the expected output gets a high live input region. Simulation must
    # physically populate this region through CPU AW/W, then read it back.
    with (case/'golden.mem').open('a') as f:
        for offset in range(0,len(raw),16):
            address=0x03f00000+offset;value=int.from_bytes(raw[offset:offset+16],'little')
            f.write(f'{(address<<256)|(((1<<128)-1)<<128)|value:072x}\n')
    info['golden']+=len(raw)//16
    slots=1<<max(8,(2*(info['initial']+len(raw)//16)-1).bit_length())
    # The physical board reserves low DDR for raw frames and adds 64 MiB to
    # CPU accesses. A larger sparse table avoids alias clusters between these
    # distant addresses without changing the validated DDR model's hash/logic.
    if args.preprocess:slots=max(slots,1<<24)

    def run(name,command,cwd=case):
        with (case/(name+'.log')).open('w') as log:
            result=subprocess.run(list(map(str,command)),cwd=cwd,stdout=log,stderr=subprocess.STDOUT)
        if result.returncode:raise RuntimeError(name+' failed: '+str(case/(name+'.log')))

    lib=subprocess.check_output(['riscv64-unknown-elf-gcc','-march=rv32i','-mabi=ilp32','-print-libgcc-file-name'],text=True).strip()
    run('firmware',['riscv64-unknown-elf-gcc','-march=rv32im','-mno-div','-mabi=ilp32','-O2','-mno-relax',
        '-msmall-data-limit=0','-ffreestanding','-fno-builtin','-nostdlib','-nostartfiles','-Wall','-Wextra','-Werror',
        *(['-DBOARD_PREPROCESS'] if args.preprocess else []),
        '-DAI_DDR_BYTES=0x04000000u','-I',ROOT/'csrc/software','-T',ROOT/'firmware/ai_link.ld','-Wl,-Map=runner.map','-o','runner.elf',
        ROOT/'firmware/start.S',ROOT/'sim/ai/board_network_runner.c',ROOT/'csrc/software/ai_runtime.c',
        ROOT/'csrc/software/ai_postprocess.c',lib])
    for section,name in [('.text','runner.bin'),('.data','runner.data.bin')]:
        run(name,['riscv64-unknown-elf-objcopy','-j',section,'-O','binary','runner.elf',name])
    code=(case/'runner.bin').read_bytes();data=(case/'runner.data.bin').read_bytes()
    if len(code)>32768 or len(data)>49152:raise ValueError('Runner exceeds board ROM/RAM budget')
    (case/'runner.hex').write_text(''.join(f'{int.from_bytes(code[n:n+4],"little"):08x}\n' for n in range(0,len(code),4)))
    (case/'runner.data').write_text(''.join(f'{v:02x}\n' for v in data) or '00\n')

    stubs=[]
    for name in ['pcie_test','PLL_CLK','ddr_2_fifo']:
        path=ROOT/'ipcore'/name/(name+'.v');body=''
        if name=='pcie_test':body='assign pclk=0;assign pclk_div2=0;assign ref_clk=0;assign core_rst_n=0;'
        elif name=='ddr_2_fifo':body='assign rd_empty=1;assign almost_empty=1;assign wr_full=0;assign wr_water_level=0;assign rd_data=0;'
        stubs.append(ports(path,name).replace('endmodule',body+'\nendmodule'))
    path=ROOT/'rtl/pcie/dma/ips2l_pcie_dma_ram/ips2l_pcie_dma_ram.v'
    stubs.append(ports(path,path.stem))
    stub=case/'external_stubs.v';stub.write_text('\n'.join(stubs))
    excluded={'memory_core.v','ROM_core.v','multiplier_core.v','acore_fetch_memory.v',
              'multiply_adder.v','multiply_adder_w8a16.v','video_async_fifo.v','MuxKeyInternal.v'}
    sources=[path for path in sorted((ROOT/'rtl').glob('*.v')) if path.name not in excluded]
    for directory,pattern in [('rtl/video','**/*.v'),('rtl/rk_fspi','*.v'),('board','*.v'),
                              ('sim/models','*.v'),('ipcore/pcie_test/rtl/hsst_pipe','*.v')]:
        sources.extend(path for path in sorted((ROOT/directory).glob(pattern))
                       if path.name!='multiply_adder_w8a16.v' and not(args.preprocess and path.name=='pango_pool_sum_ram.v'))
    sources.extend(path for path in sorted((ROOT/'rtl/pcie/dma').rglob('*.v')) if 'ips2l_pcie_dma_ram' not in path.parts)
    sources += [ROOT/'rtl/multiply_adder_w8a16.v',ROOT/'sim/ddr3/ddr3.sv',
                ROOT/'sim/ai/TB_board_ai_network.v',stub]
    if not args.preprocess:sources.append(ROOT/'sim/video/fifo_2_ddr_model.v')
    ip=ROOT/'ipcore/pango_ai_multadd'
    sources.extend(ip/item.attrib['pathname'] for item in ET.parse(ip/'pango_ai_multadd.idf').findall('file_list/source/file'))
    vendor=args.pds_root.resolve()/'arch/vendor/pango/verilog/simulation'
    sources += [vendor/'GTP_APM_E2.v',vendor/'GTP_GRS.v']
    if args.preprocess:
        for name in ['fifo_2_ddr','pango_pool_sum_ram']:
            ip=ROOT/'ipcore'/name
            sources.extend(ip/item.attrib['pathname'] for item in ET.parse(ip/(name+'.idf')).findall('file_list/source/file'))
        sources.append(vendor/'GTP_DRM36K_E1.v')
    binary=case/'obj/check'
    signature={str(path):sha(path) for path in sources+[ROOT/'sim/ai/ai_network_checks.vh',
        ROOT/'sim/ai/board_network_runner.c',ROOT/'csrc/software/ai_runtime.c',ROOT/'csrc/software/ai_postprocess.c',Path(__file__).resolve()]}
    info.update(hardware_tested=False,board_top=True,dual_issue=True,live_input=0x03f00000,
                physical_cpu_offset=0x04000000,staged_bytes=294912,slots=slots,vendor_ai_mac=True,
                hardware_preprocess=args.preprocess,vendor_fifo_and_pool_ram=args.preprocess,
                sources=signature,runner_sha256=sha(case/'runner.bin'))
    (case/'fixtures.json').write_text(json.dumps(info,indent=2)+'\n')
    print('Full board fixture ready: 99 tasks, '+str(info['golden'])+' checked DDR words; compiling actual board hierarchy.',flush=True)
    if args.prepare_only:return
    run('compile',['verilator','--binary','--timing','--assert','--no-sched-zero-delay','-O3','-CFLAGS','-O3',
        '-j',args.jobs,'-Wno-fatal','-Wno-TIMESCALEMOD','--top-module','TB_board_ai_network',
        '--Mdir',case/'obj','-o','check','-I'+str(ROOT/'sim/ai'),f'-DDDR3_MODEL_SLOTS={slots}',
        '-DDDR3_MODEL_STRICT_READS','-DPROG_FILE="runner.hex"','-DDATA_FILE="runner.data"',
        *(['-GPREPROCESS=1','-DNETWORK_BOARD_PREPROCESS'] if args.preprocess else []),*sources])
    command=['stdbuf','-oL',str(binary),f'+TASK_INITIAL={info["initial"]}',f'+TASK_GOLDEN={info["golden"]}',
        '+NETWORK_TASKS=99','+NETWORK_START=0',f'+BOARD_INPUT_SOURCE={package.header[8]}',
        '+ddr3_random_stalls=1',*sim_args]
    print('Starting full board run with DDR stalls; progress: '+str(case/'run.log'),flush=True)
    start=time.monotonic()
    with (case/'run.log').open('w') as log:
        process=subprocess.Popen(command,cwd=case,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        for line in process.stdout:log.write(line);log.flush();print(line,end='',flush=True)
        if process.wait():raise RuntimeError('Full board network failed; see '+str(case/'run.log'))
    text=(case/'run.log').read_text();metrics=net.check_sim_log(text,info)
    if 'PASS board_ai_ddr' not in text:raise RuntimeError('Missing input staging/binding confirmation')
    save_cpu_detections(case,info)
    result=dict(passed=True,scope=__doc__,**info,**metrics,simulation_seconds=time.monotonic()-start)
    (case/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    (ROOT/'reports/ai_port/full_board_network.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS full board AI: real CPU DDR staging/readback, 99 RTL tasks, all tensors/guards and CPU detections.',flush=True)


if __name__=='__main__':main()
