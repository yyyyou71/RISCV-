#!/usr/bin/env python3
"""对拍 96 位重定标、正负半整数舍入、饱和、反压及复位。"""
import sys
sys.dont_write_bytecode = True
import json
import random
import subprocess
from pathlib import Path
from quant_reference import requant_int8

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/requant_int8'


def run(args, log):
    result = subprocess.run([str(x) for x in args], cwd=OUT, capture_output=True, text=True, timeout=120)
    content = result.stdout + result.stderr
    (OUT/log).write_text(content)
    if result.returncode:
        raise RuntimeError(content[-4000:])
    return content


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # 人工可核对的锚点，约束参考本身的语义。
    for value, m, s, relu, expected in [(1,1,1,False,1),(-1,1,1,False,-1),
            (5,1,1,False,3),(-5,1,1,False,-3),(255,1,1,False,127),
            (-257,1,1,False,-128),(-128,1,0,True,0),(-(1<<63),1,63,False,-1),
            ((1<<63)-1,(1<<31)-1,94,False,1)]:
        assert requant_int8(value,m,s,relu) == expected
    vectors = []
    def emit(value,m,s,relu):
        bad = m >= (1<<31) or s > 95
        expected = 0 if bad else requant_int8(value,m,s,relu)
        vectors.append((value & ((1<<64)-1)) | (m<<64) | (s<<96) |
                       (int(relu)<<128) | ((expected&255)<<136) | (int(bad)<<144))
    for v in [-(1<<63),-(1<<63)+1,-257,-256,-255,-129,-128,-127,-5,-3,-1,0,1,3,5,127,128,255,256,257,(1<<63)-1]:
        for m in [0,1,3,(1<<31)-1]:
            for s in [0,1,2,7,31,32,63,64,93,94,95]:
                for relu in [False,True]: emit(v,m,s,relu)
    rng = random.Random(0x20261026)
    for _ in range(1000):
        emit(rng.randrange(-(1<<63),1<<63),rng.randrange(1<<31),rng.randrange(96),bool(rng.randrange(2)))
    for m,s in [(1<<31,0),((1<<32)-1,1),(1,96),(1,(1<<32)-1)]:
        emit(-19,m,s,False)
    (OUT/'vectors.mem').write_text(''.join(f'{v:048x}\n' for v in vectors))
    run(['iverilog','-g2012','-s','TB_requant_int8','-o',OUT/'test.vvp',
         ROOT/'Iverilog/TB_requant_int8.v',ROOT/'vsrc/requant_int8.v'],'compile.log')
    output = run(['vvp',OUT/'test.vvp',f'+COUNT={len(vectors)}'],'simulation.log')
    if 'PASS requant ' not in output: raise RuntimeError('missing PASS')
    run(['verilator','--lint-only','-Wall','--top-module','requant_int8',ROOT/'vsrc/requant_int8.v'],'lint.log')
    (OUT/'result.json').write_text(json.dumps(dict(vectors=len(vectors),lint=True),indent=2)+'\n')
    print(output.strip())


if __name__ == '__main__': main()
