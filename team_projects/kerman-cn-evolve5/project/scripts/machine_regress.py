import argparse,csv,hashlib,json,os,shutil,sys
from pathlib import Path
from datetime import datetime,timezone
from regress import PROJECT,run_command
from build_coremark import DEFAULT_GCC
sys.path.insert(0,str(PROJECT/'tests'))
from machine_programs import programs
from bp_programs import prediction_programs
from generate import write_image
from cache_machine_tb import cached_testbench
from cache_programs import cache_programs
from m_interrupt_programs import m_interrupt_programs,inject_m_irq
from front_configs import CONFIGS,parameters
from dual_machine_programs import programs as dual_programs,extend_tb
from lsu_irq_programs import programs as lsu_irq_programs,extend as extend_lsu_irq

def main():
    p=argparse.ArgumentParser(); p.add_argument('--gcc',type=Path,default=DEFAULT_GCC)
    p.add_argument('--vivado',type=Path,default=Path(r'D:\Vivado_2025\2025.2\Vivado'))
    p.add_argument('--build-dir',type=Path)
    p.add_argument('--bp-enable',type=int,choices=(0,1),default=1)
    p.add_argument('--bp-index-bits',type=int,default=5)
    p.add_argument('--reports',type=Path)
    p.add_argument('--cache-enable',type=int,choices=(0,1),default=1)
    p.add_argument('--m-enable',type=int,choices=(0,1),default=0)
    p.add_argument('--config',choices=CONFIGS,default='baseline')
    a=p.parse_args()
    a.bp_index_bits=CONFIGS[a.config]['bp_index_bits']
    build=(a.build_dir or PROJECT.parents[1]/'work'/f'evolve5_machine_m{a.m_enable}_c{a.cache_enable}_bp{a.bp_enable}').resolve(); build.mkdir(parents=True,exist_ok=True)
    reports=a.reports or PROJECT/'reports/cache/machine'/f'cache{a.cache_enable}_bp{a.bp_enable}'; reports.mkdir(parents=True,exist_ok=True)
    state={'status':'running','started_utc':datetime.now(timezone.utc).isoformat()}; record=reports/'core_tests.json'; record.write_text(json.dumps(state))
    try:
        env=os.environ.copy(); env['PROCESSOR_ARCHITECTURE']='AMD64'; manifest=[]
        cfg=CONFIGS[a.config]
        cases=programs(0x20000|(a.m_enable<<16)|(a.bp_index_bits<<8)|(cfg['dual_enable']<<2)|(cfg['wide_fetch']<<3)|(cfg.get('pair_jalr',0)<<1)|(cfg.get('pair_branch',0)<<4)|(cfg.get('pair_memory',0)<<5)|(cfg.get('fast_store',0)<<6)|(cfg.get('fast_mul',0)<<7)|(cfg.get('pair_mul',0)<<13)|a.bp_enable,0x40000100|(a.m_enable<<12))+prediction_programs()+cache_programs()
        if a.m_enable: cases+=m_interrupt_programs(bool(cfg['dual_enable']))
        if cfg['dual_enable'] and cfg['wide_fetch'] and a.cache_enable: cases+=dual_programs(cfg)
        if cfg.get('pair_memory'):cases+=lsu_irq_programs()
        (build/'link.ld').write_text('OUTPUT_ARCH(riscv)\nENTRY(_start)\nSECTIONS { . = 0; .text : { *(.text*) } .data : { *(.data*) } /DISCARD/ : { *(.riscv.attributes) *(.comment) } }\n')
        for case in cases:
            name=case['name']; source=build/(name+'.S'); source.write_text(case['asm'],encoding='ascii')
            elf=build/(name+'.elf'); binary=build/(name+'.bin')
            run_command([a.gcc,'-march=rv32im_zicsr2p0' if a.m_enable else '-march=rv32i_zicsr2p0','-mabi=ilp32','-mno-relax','-nostdlib','-nostartfiles','-Wl,--no-relax','-T',build/'link.ld',source,'-o',elf],build,build/(name+'.compile.log'),env)
            run_command([str(a.gcc).replace('gcc.exe','objcopy.exe'),'-O','binary',elf,binary],build,build/(name+'.objcopy.log'),env)
            assert binary.stat().st_size<32768
            write_image(build/(name+'.hex'),binary.read_bytes())
            for imode,dmode in case['profiles']:
                manifest.append(f'{name}_i{imode}d{dmode} {name}.hex {imode} {dmode} {case["scene"]} {case["irq"]} {case["trap"]}')
        (build/'manifest.txt').write_text('\n'.join(manifest)+'\n')
        (build/'args.txt').write_text('--testplusarg MANIFEST=manifest.txt\n')
        vb=a.vivado/'bin'; sources=sorted((PROJECT/'rtl').glob('*.v'))+sorted((PROJECT/'rtl/cache').glob('*.v'))
        tb=(PROJECT/'sim/tb_machine.sv').read_text().replace('rv32_core dut(',f'rv32_core #(.M_ENABLE({a.m_enable}),.BP_ENABLE({a.bp_enable}),{parameters(CONFIGS[a.config])}) dut(')
        tb=cached_testbench(tb,a.cache_enable,CONFIGS[a.config]['wide_fetch'])
        if a.m_enable: tb=inject_m_irq(tb)
        if cfg.get('fast_mul'):
            tb=tb.replace('scene==17 && dut.m_extension.unit.state==1','scene==17 && dut.md_request && dut.md_ready')
        tb=extend_tb(tb)
        if cfg.get('pair_memory'):tb=extend_lsu_irq(tb)
        (build/'tb_machine.sv').write_text(tb,encoding='utf-8')
        run_command([vb/'xvlog.bat','-sv','-i',PROJECT/'rtl',*sources,PROJECT/'sim/burst_word_test_adapter.sv',build/'tb_machine.sv'],build,build/'compile.log',env)
        run_command([vb/'xelab.bat','tb_machine','-s','machine_core','-mt','4'],build,build/'elaborate.log',env)
        text=run_command([vb/'xsim.bat','machine_core','-runall','-f','args.txt'],build,build/'simulate.log',env)
        assert 'MACHINE_REGRESSION_PASS' in text,text[-6000:]
        rows=list(csv.DictReader((build/'machine_cases.csv').open())); assert len(rows)==len(manifest)
        for file in build.iterdir():
            if file.is_file() and file.suffix in ('.S','.elf','.bin','.hex','.log','.csv','.txt','.sv'): shutil.copy2(file,reports/file.name)
        if a.bp_enable:
            for row in rows:
                if row['name'].startswith('bp_'):
                    assert int(row['bp_hits'])>0 and int(row['bp_mispredictions'])>0,'Predictor scenario was not exercised: '+row['name']
        if a.cache_enable:
            for key in ('icache_hits','icache_misses','dcache_hits','dcache_misses','dcache_write_hits'):
                assert sum(int(row[key]) for row in rows)>0,'Cache path not exercised: '+key
        state.update(status='passed',cases=rows,programs=len(cases),csr_random_operations=288,cache_enabled=bool(a.cache_enable),transport='burst_cache_with_randomized_word_BFM',
                     branch_prediction={'enabled':bool(a.bp_enable),'index_bits':a.bp_index_bits},m_enabled=bool(a.m_enable),config=a.config,
                     completed_utc=datetime.now(timezone.utc).isoformat(),hardware_tested=False,
                     source_sha256={f.relative_to(PROJECT).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in (PROJECT/'rtl').rglob('*') if f.is_file()})
        record.write_text(json.dumps(state,indent=2),encoding='utf-8'); print('MACHINE_TESTS_PASS '+str(len(rows)),flush=True)
    except Exception as exc:
        state.update(status='failed',error=str(exc)); record.write_text(json.dumps(state,indent=2),encoding='utf-8'); raise

if __name__=='__main__': main()
