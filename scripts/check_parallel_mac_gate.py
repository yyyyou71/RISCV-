"""Check the four-product MAC using actual generated multiplier IP and a PDS netlist.

Windows/PDS/ModelSim check; no firmware, FPGA bitstream, or project is changed.
The gate stage checks functional synthesis, not PHY/DRAM or routed delays.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--pds-root',type=Path,default=Path('C:/diskE/FPGA_Learning/PGenvironment/PDS_2022.2-SP6.1'))
    parser.add_argument('--modelsim',type=Path,default=Path('C:/diskE/modelsim/win64'))
    args=parser.parse_args()
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    env=os.environ.copy()
    if os.name=='nt':
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
            for name in ['PANGO_LICENSE_FILE','MGLS_LICENSE_FILE','LM_LICENSE_FILE']:
                try:env[name]=winreg.QueryValueEx(key,name)[0]
                except FileNotFoundError:pass

    def run(command,folder,name,timeout=240):
        with (folder/name).open('w',encoding='utf-8') as log:
            process=subprocess.run(list(map(str,command)),cwd=folder,env=env,
                stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
        return process.returncode,(folder/name).read_text(encoding='utf-8',errors='replace')

    sources=[ROOT/'rtl/conv_mac_tile.v',ROOT/'rtl/multiply_adder_w8a16.v',
        ROOT/'ipcore/pango_ai_multadd/pango_ai_multadd.v',
        ROOT/'ipcore/pango_ai_multadd/rtl/ipm2l_multadd_v1_3_pango_ai_multadd.v']
    # Only top-level parameter defaults change in this isolated deployment copy.
    selected=out/'conv_mac_tile_selected.v'
    selected.write_text(sources[0].read_text(encoding='utf-8').replace('REDUCE_PAIRS = 1','REDUCE_PAIRS = 2').replace('ACT_WIDTH = 8','ACT_WIDTH = 16'),encoding='utf-8')
    synthesis_sources=[selected,*sources[1:]]
    tb=ROOT/'sim/ai/TB_parallel_mac.v'
    recipe='set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484\n'
    for source in synthesis_sources:recipe+='add_design -verilog {'+source.as_posix()+'}\n'
    recipe+='compile -top_module conv_mac_tile\nsynthesize -ads -frequency 131.25\n'
    (out/'synth.tcl').write_text(recipe,encoding='utf-8')
    code,log=run([args.pds_root/'bin/pds_shell.exe','-file','synth.tcl','-project_name','parallel_mac_gate'],out,'synthesis.log')
    if code or re.search(r'^E:',log,re.M):raise RuntimeError(log[-2000:])
    net=out/'synthesize/conv_mac_tile_syn.vm'
    text=net.read_text(encoding='utf-8',errors='replace')
    dependency=r'\b((?:GTP_|INT_)[A-Z0-9_]+)\s+(?:/\*|#|[A-Za-z_(\\])'
    lib=args.pds_root/'arch/vendor/pango/verilog/simulation'
    queue=set(re.findall(dependency,text,re.M));seen={'GTP_GRS'}
    primitives=[lib/'GTP_GRS.v']
    while queue:
        name=queue.pop()
        if name in seen:continue
        source=lib/(name+'.v')
        if not source.is_file():raise RuntimeError('Missing primitive '+name)
        seen.add(name);primitives.append(source)
        queue.update(re.findall(dependency,source.read_text(encoding='utf-8',errors='replace'),re.M))
    results={}
    for kind,design in [('gate',[net])]:
        folder=out/kind;folder.mkdir()
        commands=[([args.modelsim/'vlib.exe','work'],'vlib.log'),
            ([args.modelsim/'vmap.exe','-c'],'vmap.log'),
            ([args.modelsim/'vlog.exe','-sv','-work','work','+incdir+'+str(lib),
                *(['+define+GATE_NETLIST'] if kind=='gate' else []),
                *primitives,*design,tb],'compile.log')]
        for command,name in commands:
            code,log=run(command,folder,name)
            if code or '** Error' in log:raise RuntimeError(log[-2000:])
        code,log=run([args.modelsim/'vsim.exe','-c','-quiet','-onfinish','exit',
            'work.TB_parallel_mac','-do','run -all; quit -code 0 -f'],folder,'simulation.log')
        passed=code==0 and 'PARALLEL_MAC_PASS cases=16' in log and '** Fatal' not in log and '** Error' not in log
        results[kind]={'passed':passed,'exit_code':code,
            'events':[line for line in log.splitlines() if any(word in line for word in ['PASS','** Fatal','mismatch'])]}
        print(kind,json.dumps(results[kind]),flush=True)
    mapping={}
    passed=all(result['passed'] for result in results.values())
    report={'passed':passed,'scope':'ACT_WIDTH=16 REDUCE_PAIRS=2 MAC with actual vendor IP, signed extremes and stalls; no SDF or board validation',
        'mapping':mapping,'results':results,
        'sources':{str(source.relative_to(ROOT)):hashlib.sha256(source.read_bytes()).hexdigest() for source in sources+[tb]},
        'netlist_sha256':hashlib.sha256(net.read_bytes()).hexdigest()}
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'passed':passed,'mapping':mapping}),flush=True)
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
