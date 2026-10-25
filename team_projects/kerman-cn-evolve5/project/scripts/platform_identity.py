"""Firmware-printed hardware identity is checked per run; it is not bitstream attestation."""
import re
FIELDS=('HW_ID','HW_CFG','CLOCK','CACHE_BYTES','LINE_BYTES','SETS','BP_ENTRIES','WAIT','GAP')
HEX_FIELDS={'HW_ID','HW_CFG'}
def expected_identity(prepared):
    c=prepared['caches']; b=prepared['backend']; p=prepared['branch_prediction']
    flags=int(c['icache_enabled'])|(int(c['dcache_enabled'])<<1)|(int(b['kind']=='shared_burst')<<2)|(int(b['line_bursts'])<<3)|(int(p['enabled'])<<4)|(int(prepared.get('isa',{}).get('m_enabled',False))<<5)
    return dict(zip(FIELDS,(0x43414333,flags,prepared['clock_hz'],c['bytes_each'],4<<c['line_word_bits'],1<<c['set_bits'],p['entries'],b['first_wait_cycles'],b['beat_gap_cycles'])))
def parse_identity(line):
    pattern=' '.join(k+'=(?P<'+k+'>'+('[0-9a-fA-F]{8}' if k in HEX_FIELDS else r'\d+')+')' for k in FIELDS)
    match=re.fullmatch(pattern,line)
    if not match: return None
    parts=match.groupdict()
    try: return {k:int(parts[k],16 if k in HEX_FIELDS else 10) for k in FIELDS}
    except ValueError: return None
def check_runs(text,prepared,build_id,printed_flags):
    expected=expected_identity(prepared); current_hw=None; current_build=None; current_bp=None; boot_seen=False; runs=[]; flags=[]
    bp=prepared['branch_prediction']; wanted_bp=(int(bp['enabled']),bp['entries'],bp['implementation_id'])
    for line in text.splitlines():
        line=line.strip()
        if line in ('RV32I COREMARK 1.0','RISC-V COREMARK 1.0'): boot_seen=True; current_hw=None; current_build=None; current_bp=None
        elif line.startswith('BUILD='): current_build=line.split('=',1)[1]
        elif line.startswith('HW_ID='): current_hw=parse_identity(line)
        elif line.startswith('BP_ENABLE='):
            m=re.fullmatch(r'BP_ENABLE=(\d+) BP_ENTRIES=(\d+) IMPL_ID=([0-9a-fA-F]{8})',line)
            current_bp=(int(m[1]),int(m[2]),int(m[3],16)) if m else None
        elif line.startswith('CM_BEGIN '): runs.append(boot_seen and current_hw==expected and current_build==build_id and current_bp==wanted_bp)
        elif line.startswith('Compiler flags'): flags.append(line.split(':',1)[1].strip()==printed_flags)
    return {'expected_hardware':expected,'identity_checks':runs,'flags_checks':flags,'identity_passed':bool(runs) and all(runs),'flags_passed':bool(flags) and all(flags)}
