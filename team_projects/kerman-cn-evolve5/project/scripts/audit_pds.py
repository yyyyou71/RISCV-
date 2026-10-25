"""CACHE3 sign-off: inspect actual mapped primitives, ROM bits and all timing corners."""
import hashlib,json,re,shutil
from pathlib import Path
from datetime import datetime,timezone
from prepare_board import PROJECT,DEFAULT_WORK
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def audit(build,report=None):
    report=report or PROJECT/'reports/pds/audit'; report.mkdir(parents=True,exist_ok=True)
    prepared=json.loads((build/'prepared.json').read_text())
    vm=build/'synthesize/board_top_syn.vm'; net=vm.read_text()
    blocks=re.findall(r'GTP_DRM36K_E1\s*(?:/\*.*?\*/)?\s*#\((.*?)\)\s+(\S+)\s*\((.*?)\);',net,re.S)
    roms=[x for x in blocks if 'rom_bq' in x[2]]
    assert len(blocks)==16 and len(roms)==8,'Unexpected block RAM mapping'
    words=[0]*8192; lanes=[]
    for params,name,ports in roms:
        assert '.DATA_WIDTH_A(4)' in params and '.RAM_MODE("SINGLE_PORT")' in params
        bits=list(map(int,re.findall(r'rom_bq\s*\[\s*(\d+)\s*\]',ports)))
        assert len(bits)==4 and bits==list(range(min(bits)+3,min(bits)-1,-1)) and min(bits)%4==0
        lane=min(bits)//4; lanes.append(lane)
        assert re.search(r"\.WEA\s*\(1'b0\)",ports),'ROM is writable'
        vals={int(n,16):int(d.replace('_',''),2 if base.lower()=='b' else 16) for n,base,d in re.findall(r"\.INIT_([0-9A-F]+)\(288'([bBhH])([0-9a-fA-F_]+)\)",params)}
        assert set(vals)==set(range(128))
        for addr in range(8192): words[addr]|=((vals[addr//64]>>((addr%64//2)*9+(addr%2)*4))&15)<<(lane*4)
    assert sorted(lanes)==list(range(8))
    assert words==[int(x,16) for x in (build/'firmware_rom.hex').read_text().splitlines()],'Mapped ROM differs from software image'
    initial={}
    for label,value in [('hold_reset',1),('\\release_sync[0]',0),('\\release_sync[1]',0)]:
        found=re.search(r'GTP_DFF(?:_[A-Z]+)?\s*/\*\s*'+re.escape(label)+r'\s*\*/\s*#\((.*?)\)\s+\S+\s*\(',net,re.S)
        assert found and '.GRS_EN("TRUE")' in found[1] and f".INIT(1'b{value})" in found[1],label
        initial[label]=value
    mapping=(build/'synthesize/apm_drm_lutram_utilization.log').read_text()
    banks=re.findall(r'\|\s*(u_soc/[id]_cache/[^|]*bytes\[\d\]\.bank[01])\s*\|\s*(\d+) x (\d+)\s*\|',mapping)
    wide=bool(prepared.get('issue',{}).get('wide_fetch',False))
    expected_i=8*int(prepared['caches']['icache_enabled'])*(1+int(wide))
    expected_d=8*int(prepared['caches']['dcache_enabled'])
    expected=expected_i+expected_d
    assert len(banks)==expected,'Cache data banks did not map to distributed RAM'
    assert sum('/i_cache/' in n for n,_,_ in banks)==expected_i
    assert sum('/d_cache/' in n for n,_,_ in banks)==expected_d
    assert sum('second_port' in n for n,_,_ in banks)==8*int(wide)*int(prepared['caches']['icache_enabled'])
    assert all(int(depth)==128 and int(width)==8 for _,depth,width in banks)
    snr=(build/'synthesize/board_top.snr').read_text()
    luts=int(re.search(r'Total LUTs: (\d+)',snr)[1]); regs=int(re.search(r'Total Registers: (\d+)',snr)[1]); latches=int(re.search(r'Total Latches: (\d+)',snr)[1])
    assert latches==0
    rtr=(build/'place_route/board_top.rtr').read_text()
    assert 'All Constraints Met.' in rtr and 'PG2L100H' in rtr and 'FBG484' in rtr,'Timing/target sign-off failed'
    timing={}
    for kind in ('Setup','Hold'):
        for corner in ('Slow','Fast'):
            part=re.search(kind+r' Summary\('+corner+r' Corner\):(.*?)(?=\n[A-Za-z]|\Z)',rtr,re.S)
            row=re.search(r'sys_clk\s+sys_clk\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)',part[1]) if part else None
            assert row and float(row[1])>=0 and float(row[2])==0 and int(row[3])==0
            timing[kind.lower()+'_'+corner.lower()]={'worst_slack_ns':float(row[1]),'total_negative_slack_ns':float(row[2]),'failing_endpoints':int(row[3])}
    info={'status':'passed','tool':'PDS 2022.2-SP6.1','target':'PG2L100H-6IFBG484','clock_hz':25000000,'checked_utc':datetime.now(timezone.utc).isoformat(),
        'synthesis_luts':luts,'synthesis_registers':regs,'latches':latches,'drm36k_total':16,'rom_drm36k':8,'ram_drm36k':8,
        'cache_distributed_byte_banks':len(banks),'cache_data_bits':sum(int(d)*int(w) for _,d,w in banks),
        'cache_logical_data_bits':8192*(int(prepared['caches']['icache_enabled'])+int(prepared['caches']['dcache_enabled'])),
        'icache_second_read_replica_bits':8192*int(wide)*int(prepared['caches']['icache_enabled']),'rom_words_verified':8192,
        'reset_ff_init_verified':initial,'timing':timing,'netlist_sha256':sha(vm),'combined_rtl_sha256':sha(build/'rv32_board_design.v'),
        'firmware_rom_sha256':sha(build/'firmware_rom.hex'),'electrical_signoff':prepared['electrical_confirmed'],'hardware_tested':False,
        'timing_scope':'All internal synchronous paths; inherited asynchronous pin exceptions unchanged.'}
    for name,source in {'synthesis_summary.snr':'synthesize/board_top.snr','memory_mapping.log':'synthesize/apm_drm_lutram_utilization.log',
                        'post_route_timing.rtr':'place_route/board_top.rtr','placement_routing.prr':'place_route/board_top.prr',
                        'pds_console.log':'pds_console.log','bitstream_generation.bgr':'generate_bitstream/board_top.bgr'}.items():
        shutil.copy2(build/source,report/name)
    (report/'audit.json').write_text(json.dumps(info,indent=2)); return info
