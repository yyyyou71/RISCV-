"""Small C-reference check for the new CPU first-pixel checker, not a network run."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference',type=Path,required=True)
    args=parser.parse_args()
    out=ROOT/'build/ai-first-layer/reference';out.mkdir(parents=True,exist_ok=True)
    original=args.reference/'training/export/rearch_fixed.c'
    source=out/'check.c'
    source.write_text(r'''
#define main original_reference_main
#include TRIDENT_SOURCE
#undef main
#include "ai_first_layer_quant.h"
int main(int argc,char **argv){
    unsigned n,p,c,o;uint32_t seed=0x71a53628u;
    if(argc!=2)return 2;load_bin(argv[1]);
    for(n=0;n<16;n++){
        Tensor x=t_alloc(3,3,3);uint16_t rgb[4][3];int16_t expected[32];
        memset(x.d,0,27*sizeof(*x.d));
        for(p=0;p<4;p++)for(c=0;c<3;c++){
            seed=seed*1664525u+1013904223u;
            rgb[p][c]=n==0?0:n==1?255:(seed>>24);
            x.d[(c*3+p/2)*3+p%2]=rgb[p][c];
        }
        fl_reference(rgb,expected);Tensor y=conv_layer(&x,"model.0");
        for(o=0;o<32;o++)if(expected[o]!=y.d[o*y.h*y.w]){
            fprintf(stderr,"reference mismatch patch=%u channel=%u got=%d expected=%d\n",n,o,expected[o],y.d[o*y.h*y.w]);return 1;
        }
        t_free(&x);t_free(&y);
    }
    puts("PASS first-layer CPU checker: 16 RGB patches / 512 channels vs original TridentVision C");return 0;
}
''')
    compile_result=subprocess.run(['gcc','-O2','-std=c11','-DTRIDENT_SOURCE='+json.dumps(str(original)),
                    '-I',str(ROOT/'firmware'),'-I',str(args.reference/'c_model'),str(source),'-lm','-o',str(out/'check')],
                    capture_output=True,text=True)
    (out/'compile.log').write_text(compile_result.stdout+compile_result.stderr)
    compile_result.check_returncode()
    r=subprocess.run([str(out/'check'),str(args.reference/'training/export/rearch_int8.bin')],capture_output=True,text=True,check=True)
    (out/'run.log').write_text(r.stdout+r.stderr)
    line=next(s for s in r.stdout.splitlines() if s.startswith('PASS first-layer'))
    report=dict(passed=True,scope='CPU first-pixel reference only, 16 small patches',checks=512,
                golden_source_sha256=hashlib.sha256(original.read_bytes()).hexdigest(),rtl_simulation=False,full_network=False,
                checker_sha256=hashlib.sha256((ROOT/'firmware/ai_first_layer_quant.h').read_bytes()).hexdigest())
    (ROOT/'reports/preprocess/first_layer_reference.json').write_text(json.dumps(report,indent=2)+'\n')
    print(line)


if __name__=='__main__':main()
