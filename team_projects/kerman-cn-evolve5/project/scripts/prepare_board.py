"""Prepare a self-contained PDS project; electrical confirmation is never inferred."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
from soc_regress import PROJECT,build_firmware

BOARD=PROJECT/'board'/'rk3568_mes2l100h'
DEFAULT_WORK=PROJECT.parents[1]/'work'/'evolve5_board_build'


def prepare(build,gcc,firmware=None,bp_enable=1,bp_index_bits=5,icache_enable=1,dcache_enable=1,cache_set_bits=5,cache_line_word_bits=2,
            burst_backend=1,burst_fill=1,first_wait=0,beat_gap=0,m_enable=1,
            gshare_enable=0,pht_bits=8,ras_depth=0,fetch_depth=1,fetch_bypass=0,load_forward=0,dual_enable=0,wide_fetch=0,pair_branch=0,pair_memory=0,pair_jalr=0,fast_store=0,fast_mul=0,pair_mul=0):
    assert dual_enable in (0,1) and wide_fetch in (0,1) and (not (dual_enable or wide_fetch) or fetch_depth>=2)
    assert gshare_enable in (0,1) and 2<=pht_bits<=12 and ras_depth in (0,4,8,16) and fetch_depth in (1,2,4,8) and fetch_bypass in (0,1) and load_forward in (0,1)
    if bp_enable not in (0,1) or not 2<=bp_index_bits<=8: raise ValueError('Invalid branch predictor configuration')
    if icache_enable not in (0,1) or dcache_enable not in (0,1) or not 1<=cache_set_bits<=8 or not 1<=cache_line_word_bits<=4:
        raise ValueError('Invalid cache configuration')
    if burst_backend not in (0,1) or burst_fill not in (0,1) or not 0<=first_wait<=32 or not 0<=beat_gap<=16:
        raise ValueError('Invalid backend configuration')
    if not burst_backend and (first_wait or beat_gap): raise ValueError('Latency settings apply only to the shared burst backend')
    build=build.resolve(); build.mkdir(parents=True,exist_ok=True)
    cfg=json.loads((BOARD/'electrical_review.json').read_text(encoding='utf-8'))
    pins=json.loads((BOARD/'pins.json').read_text(encoding='utf-8'))
    folder,facts=firmware if firmware is not None else build_firmware('board_demo','O2',gcc,build,os.environ.copy(),cfg['clock_hz'],cfg['baud'])
    shutil.copy2(folder/'firmware_rom.hex',build/'firmware_rom.hex')
    sources=sorted((PROJECT/'rtl').rglob('*.v'))+sorted(BOARD.glob('*.v'))
    definitions=(PROJECT/'rtl'/'rv32_defs.vh').read_text(encoding='utf-8')
    merged=[definitions]
    hashes={}
    for path in sources:
        rel=path.relative_to(PROJECT).as_posix()
        hashes[rel]=hashlib.sha256(path.read_bytes()).hexdigest()
        source=path.read_text(encoding='utf-8').replace('`include "rv32_defs.vh"','')
        if path==BOARD/'board_top.v':
            for name,value in [('DUAL_ENABLE',dual_enable),('WIDE_FETCH',wide_fetch),('PAIR_BRANCH',pair_branch),('PAIR_MEMORY',pair_memory),('PAIR_JALR',pair_jalr),('FAST_STORE',fast_store),('FAST_MUL',fast_mul),('PAIR_MUL',pair_mul)]:
                marker=f'{name}=0';assert source.count(marker)==1;source=source.replace(marker,f'{name}={value}')
            for name,default,value in [('GSHARE_ENABLE',0,gshare_enable),('PHT_BITS',8,pht_bits),('RAS_DEPTH',0,ras_depth),('FETCH_DEPTH',1,fetch_depth),('FETCH_BYPASS',0,fetch_bypass),('LOAD_FORWARD',0,load_forward)]:
                marker=f'{name}={default}'
                assert source.count(marker)==1
                source=source.replace(marker,f'{name}={value}')
            assert m_enable in (0,1)
            source=source.replace('parameter integer M_ENABLE = 1',f'parameter integer M_ENABLE = {m_enable}')
            assert source.count('parameter integer BP_ENABLE = 1')==1
            assert source.count('parameter integer BP_INDEX_BITS = 5')==1
            source=source.replace('parameter integer BP_ENABLE = 1',f'parameter integer BP_ENABLE = {bp_enable}')
            source=source.replace('parameter integer BP_INDEX_BITS = 5',f'parameter integer BP_INDEX_BITS = {bp_index_bits}')
            for name,default,value in [('ICACHE_ENABLE',1,icache_enable),('DCACHE_ENABLE',1,dcache_enable),('CACHE_SET_BITS',5,cache_set_bits),('CACHE_LINE_WORD_BITS',2,cache_line_word_bits),
                                       ('BURST_BACKEND',1,burst_backend),('BURST_FILL',1,burst_fill),('MEM_FIRST_WAIT',0,first_wait),('MEM_BEAT_GAP',0,beat_gap)]:
                marker=f'parameter integer {name} = {default}'
                assert source.count(marker)==1
                source=source.replace(marker,f'parameter integer {name} = {value}')
        merged.append('// Source: '+rel+'\n'+source)
    # A single file avoids relying on installation-specific include-path settings.
    (build/'rv32_board_design.v').write_text('\n'.join(merged),encoding='utf-8')
    confirmed=all(cfg.get(k) is True for k in ('board_revision_confirmed','bank_vccio_confirmed','uart_header_confirmed')) and bool(cfg.get('confirmation_evidence'))
    constraints=['# IO profile imported from the user-confirmed on-board baseline.' if confirmed else '# UNCONFIRMED reference IO profile.']
    for name,pin in pins.items():
        standard=cfg['reference_io_standards'][name]
        vccio={'LVCMOS15':'1.5','LVCMOS18':'1.8','LVCMOS25':'2.5','LVCMOS33':'3.3'}[standard]
        for key,value in [('PAP_IO_DIRECTION',pin['direction']),('PAP_IO_LOC',pin['ball']),
                          ('PAP_IO_VCCIO',vccio),('PAP_IO_STANDARD',standard)]:
            constraints.append('define_attribute {p:'+name+'} {'+key+'} {'+value+'}')
        if pin['direction']=='OUTPUT':
            constraints.append('define_attribute {p:'+name+'} {PAP_IO_DRIVE} {4}')
            constraints.append('define_attribute {p:'+name+'} {PAP_IO_SLEW} {SLOW}')
    (build/'board_io_reference.fdc').write_text('\n'.join(constraints)+'\n',encoding='ascii')
    shutil.copy2(BOARD/'timing.fdc',build/'timing.fdc')
    base='\n'.join([
        'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG484',
        'add_design -verilog "rv32_board_design.v"',
        'add_constraint -fdc "board_io_reference.fdc"',
        'add_constraint -fdc "timing.fdc"',
        'compile -top_module board_top',
    ])+'\n'
    (build/'compile.tcl').write_text(base,encoding='ascii')
    (build/'synthesis.tcl').write_text(base+'synthesize -ads -frequency 25\n',encoding='ascii')
    # CACHE3 starts from seed 4. The implementation runner records any per-variant
    # override; a candidate is published only after the timing audit passes.
    route_seed=4
    route=base+f'synthesize -ads -frequency 25\ndev_map\npnr -report_timing -gplace_seed {route_seed} -groute_seed {route_seed} -optimize_multi_corner_timing -fix_hold_violation -fix_hold_violation_iterations 5 -fix_hold_violation_threshold 0 -fix_hold_violation_in_route TRUE\nreport_timing -report_exception TRUE\n'
    (build/'route.tcl').write_text(route,encoding='ascii')
    # No bitstream Tcl is supplied unless the build wrapper checks sign-off.
    pds='''(_flow fab_demo "2022.2-SP6.1"
 (_version "1.1.0") (_status "initial")
 (_project (_option prj_work_dir (_string ".")) (_option prj_impl_dir (_string ".")))
 (_task tsk_setup
  (_widget wgt_select_arch (_input (_part (_family Logos2) (_device PG2L100H) (_speedgrade -6) (_package FBG484))))
  (_widget wgt_my_design_src (_input (_file "rv32_board_design.v" + "board_top" (_format verilog))))
  (_widget wgt_my_ips_src)
  (_widget wgt_import_logic_con_file (_input (_file "board_io_reference.fdc" (_format fdc)) (_file "timing.fdc" (_format fdc))))
 )
 (_task tsk_compile (_command cmd_compile (_gci_state (_integer 0))))
 (_task tsk_synthesis (_command cmd_synthesize (_gci_state (_integer 0)) (_option selected_syn_tool_opt (_integer 2))))
 (_task tsk_devmap (_command cmd_devmap (_gci_state (_integer 0))))
 (_task tsk_pnr (_command cmd_pnr (_gci_state (_integer 0))))
 (_task tsk_bitgen (_command cmd_bitgen (_gci_state (_integer 0))))
)
'''
    (build/'rv32_board.pds').write_text(pds,encoding='utf-8')
    info={'status':'prepared_for_validation','target':cfg['part'],'clock_hz':cfg['clock_hz'],
          'baud':cfg['baud'],'uart_divisor':(cfg['clock_hz']+cfg['baud']//2)//cfg['baud'],
          'electrical_confirmed':confirmed,'source_sha256':hashes,'firmware':facts,
          'route_seed':route_seed,'isa':{'m_enabled':bool(m_enable),'name':'RV32IM_Zicsr' if m_enable else 'RV32I_Zicsr'},
          'caches':{'icache_enabled':bool(icache_enable),'dcache_enabled':bool(dcache_enable),'ways':2,'set_bits':cache_set_bits,
                    'line_word_bits':cache_line_word_bits,'bytes_each':2*(1<<cache_set_bits)*(4<<cache_line_word_bits),
                    'data_policy':'write-through, no-write-allocate'},
          'backend':{'kind':'shared_burst' if burst_backend else 'legacy_dual_scalar','line_bursts':bool(burst_fill),
                     'first_wait_cycles':first_wait,'beat_gap_cycles':beat_gap,'clock_hz':cfg['clock_hz'],'ddr_connected':False},
          'branch_prediction':{'enabled':bool(bp_enable),'index_bits':bp_index_bits,'entries':1<<bp_index_bits,
                               'implementation_id':0x20000|(m_enable<<16)|(bp_index_bits<<8)|(dual_enable<<2)|(wide_fetch<<3)|(pair_jalr<<1)|(pair_branch<<4)|(pair_memory<<5)|(fast_store<<6)|(fast_mul<<7)|(pair_mul<<13)|bp_enable},
          'fast_paths':{'store_command_bypass':bool(fast_store),'multiply_request_capture':bool(fast_mul)},
          'issue':{'multiply_slot1':bool(pair_mul),'memory_slot1':bool(pair_memory),'jalr_slot1':bool(pair_jalr),'branch_slot1':bool(pair_branch),'dual_enabled':bool(dual_enable),'wide_fetch':bool(wide_fetch),'max_retire':2 if dual_enable else 1,'slot1':'independent RV32I integer ALU/LUI/AUIPC'},
          'frontend':{'gshare_enabled':bool(gshare_enable),'pht_bits':pht_bits,'ras_depth':ras_depth,'fetch_depth':fetch_depth,'fetch_bypass':bool(fetch_bypass),'load_forward':bool(load_forward)},
          'combined_rtl_sha256':hashlib.sha256((build/'rv32_board_design.v').read_bytes()).hexdigest(),
          'limitations_scope':'Preparation step only; subsequent PDS audit records implementation results',
          'limitations':['PDS implementation and DRM mapping await the subsequent audit']+
                        ([] if confirmed else ['IO voltage profile still requires physical board confirmation'])}
    (build/'prepared.json').write_text(json.dumps(info,indent=2),encoding='utf-8')
    return info


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--gcc',type=Path,default=Path(r'D:\riscv\riscv64-unknown-elf-toolchain-10.2.0-2020.12.8-x86_64-w64-mingw32\bin\riscv64-unknown-elf-gcc.exe'))
    p.add_argument('--build-dir',type=Path,default=DEFAULT_WORK)
    a=p.parse_args(); facts=prepare(a.build_dir,a.gcc)
    print(f'BOARD_PROJECT_PREPARED {a.build_dir}\nTarget={facts["target"]} clock={facts["clock_hz"]} UART divisor={facts["uart_divisor"]}')

if __name__=='__main__': main()
