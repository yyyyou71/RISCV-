"""Write target-specific Multiply-Adder IDFs only; generate/import them in PDS."""
import argparse
from pathlib import Path
from prepare_ips import DEFAULT_PDS, prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pds-root',type=Path,default=DEFAULT_PDS)
    parser.add_argument('--legacy-w8a8',action='store_true')
    args=parser.parse_args()
    options=dict(ASIZE='16',BSIZE='8',A_SIGNED='1',B_SIGNED='1',
        ASYNC_RST='0',ASYNC_RST_BOOL='0',PIPE_STATUS='3',
        INREG_EN='0',PIPEREG_EN_1='1',PIPEREG_EN_2='1',PIPEREG_EN_3='1',OUTREG_EN='0',
        DYN_ADDSUB_OP='0',ADDSUB_OP='0',OPTIMAL_TIMING='0',OPTIMAL_TIMING_BOOL='0')
    print(prepare(args.pds_root,'ipm2l_multadd','pango_ai_multadd',options))
    if args.legacy_w8a8:
        print(prepare(args.pds_root,'ipm2l_multadd','pango_ai_multadd8',dict(options,ASIZE='8')))
    print('Configuration only. Vendor HDL/IP generation and PDS import have not run.')


if __name__=='__main__':main()
