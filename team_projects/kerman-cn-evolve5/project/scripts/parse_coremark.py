"""Validate a UART log and calculate scores from exact clock-cycle counts."""
import argparse,csv,json,re
from decimal import Decimal,localcontext
from pathlib import Path

EXPECTED={'performance':{'seed1':0,'seed2':0,'seed3':102,'list':0xe714,'matrix':0x1fd7,'state':0x8e3a},
          'validation':{'seed1':0x3415,'seed2':0x3415,'seed3':102,'list':0xe3c1,'matrix':0x0747,'state':0x8d84}}

def parse_text(text,origin='unspecified',luts=None):
    rows=[]; current=None; seedcrc=None; banner_seen=any(x in text for x in ('RV32I COREMARK 1.0','RISC-V COREMARK 1.0'))
    for line in text.splitlines():
        line=line.strip()
        if line.startswith('CM_BEGIN '):
            current=dict(re.findall(r'(\w+)=([^\s]+)',line)); seedcrc=None
        elif line.startswith('seedcrc'):
            m=re.search(r'0x([0-9a-fA-F]+)',line)
            if m: seedcrc=int(m[1],16)
        elif line.startswith('CM_RESULT '):
            raw=dict(re.findall(r'(\w+)=([^\s]+)',line))
            mode=raw.get('mode')
            if not current or current.get('mode')!=mode or mode not in EXPECTED: raise ValueError('Missing or mismatched CM_BEGIN')
            values={k:int(raw[k],16 if k in ('list','matrix','state','final') else 10)
                    for k in ('iterations','cycles','clock_hz','seed1','seed2','seed3','data_size','contexts','crc_ok','time_ok','score_valid','list','matrix','state','final')}
            if values['clock_hz']!=25000000 or current.get('clock_hz')!='25000000': raise ValueError('Unexpected clock configuration')
            if raw.get('tick_unit')!='us': raise ValueError('Unexpected timer unit')
            if any(values[k] not in (0,1) for k in ('crc_ok','time_ok','score_valid')): raise ValueError('Invalid result flags')
            if values['data_size']!=2000 or values['contexts']!=1: raise ValueError('Nonstandard data size/context count')
            if values['iterations']<=0 or values['cycles']<=0: raise ValueError('Nonpositive iteration count/time')
            requested=int(current['requested_iterations'])
            if requested<0 or (requested!=0 and requested!=values['iterations']):
                raise ValueError('Reported iterations differ from the requested run')
            expected=EXPECTED[mode]
            crc_ok=all(values[k]==v for k,v in expected.items()) and seedcrc==(0xe9f5 if mode=='performance' else 0x18f2)
            time_ok=values['cycles']>=values['clock_hz']*10
            if bool(values['crc_ok'])!=crc_ok or bool(values['time_ok'])!=time_ok or bool(values['score_valid'])!=(crc_ok and time_ok):
                raise ValueError('Firmware flags disagree with independent CRC/duration validation')
            row={'mode':mode,'origin':origin,**values,'standard_crc_valid':crc_ok,'duration_valid':time_ok,
                 'eligible_board_measurement':origin=='board' and crc_ok and time_ok,'requested_iterations':requested}
            with localcontext() as ctx:
                ctx.prec=32
                row['seconds']=str(Decimal(values['cycles'])/Decimal(values['clock_hz']))
                if crc_ok and time_ok:
                    score=Decimal(values['iterations'])*Decimal(values['clock_hz'])/Decimal(values['cycles'])
                    row['iterations_per_second']=str(score)
                    row['coremark_per_mhz']=str(Decimal(values['iterations'])*Decimal(1000000)/Decimal(values['cycles'])) if mode=='performance' else None
                    if luts and mode=='performance': row['coremark_per_lut']=str(score/Decimal(luts))
                else:
                    row['iterations_per_second']=None; row['coremark_per_mhz']=None
            rows.append(row); current=None
    if not rows: raise ValueError('No complete CM_RESULT records found')
    both=all(any(r['mode']==mode and r['standard_crc_valid'] and r['duration_valid'] for r in rows) for mode in EXPECTED)
    for row in rows:
        row['reportable_coremark']=origin=='board' and both and row['mode']=='performance' and row['standard_crc_valid'] and row['duration_valid']
    return {'origin':origin,'coremark_banner_present':banner_seen,'runs':rows,
            'both_standard_seed_sets_valid':both,
            'hardware_measurement':origin=='board','luts':luts,
            'note':'Short runs never receive a score. Simulation results are not board measurements. Use the matching firmware/compiler/memory configuration.'}

def main():
    p=argparse.ArgumentParser(); p.add_argument('log',type=Path)
    p.add_argument('--origin',choices=['board','simulation','unspecified'],default='unspecified')
    p.add_argument('--luts',type=int); p.add_argument('--output',type=Path)
    a=p.parse_args()
    result=parse_text(a.log.read_text(encoding='utf-8-sig',errors='strict'),a.origin,a.luts)
    dest=a.output or a.log.with_suffix('.coremark.json')
    dest.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps(result,indent=2,ensure_ascii=False))

if __name__=='__main__': main()
