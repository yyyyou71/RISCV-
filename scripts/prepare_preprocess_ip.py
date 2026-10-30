"""Prepare the 48x512 accumulator RAM; --generate runs IP generation only."""
import argparse
import os
import subprocess
from prepare_ips import DEFAULT_PDS, ROOT, prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pds-root',type=type(DEFAULT_PDS),default=DEFAULT_PDS)
    parser.add_argument('--generate',action='store_true')
    args=parser.parse_args()
    options=dict(CAS_MODE_SEL='DRM36K',CAS_MODE='36K',RESET_TYPE='SYNC',SAMEWIDTH_EN='1',
        WR_ADDR_WIDTH='9',RD_ADDR_WIDTH='9',WR_DATA_WIDTH='48',RD_DATA_WIDTH='48',
        WR_BYTE_EN='0',BE_WIDTH='6',RD_BE_WIDTH='6',WR_CLK_EN='0',RD_CLK_EN='1',
        OUTPUT_REG='0',INIT_EN='0',INIT_FILE='NONE',RST_VAL_EN='0')
    path=prepare(args.pds_root,'ipm2l_sdpram','pango_pool_sum_ram',options)
    print(path,flush=True)
    if args.generate:
        if os.name=='nt' and not os.environ.get('PANGO_LICENSE_FILE'):
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,'Environment') as key:
                os.environ['PANGO_LICENSE_FILE']=winreg.QueryValueEx(key,'PANGO_LICENSE_FILE')[0]
        subprocess.run([str(args.pds_root/'bin/ip_generate.exe'),'-i',str(path),'-disable-syn'],cwd=ROOT,check=True,timeout=60)


if __name__=='__main__':main()
