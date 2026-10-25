"""Independent mathematical ALU vectors, including overflow and shift edges."""
import random
from reference import MASK, sext


def make_vectors(path):
    edges = [0,1,2,31,32,33,63,0x7fffffff,0x80000000,0x80000001,0xfffffffe,0xffffffff]
    operations = {
        0:lambda a,b:a+b, 1:lambda a,b:a-b, 2:lambda a,b:a * (2 ** (b & 31)),
        3:lambda a,b:int(sext(a,32) < sext(b,32)), 4:lambda a,b:int(a < b),
        5:lambda a,b:a^b, 6:lambda a,b:a // (2 ** (b & 31)),
        7:lambda a,b:sext(a,32) // (2 ** (b & 31)),
        8:lambda a,b:a|b, 9:lambda a,b:a&b, 10:lambda a,b:b, 15:lambda a,b:0,
    }
    inputs = [(a,b,op) for op in operations for a in edges for b in edges]
    rng = random.Random(20260921)
    inputs.extend((rng.getrandbits(32),rng.getrandbits(32),rng.choice(list(operations))) for _ in range(1024))
    path.write_text(''.join(f'{a:08x} {b:08x} {op:08x} {operations[op](a,b)&MASK:08x}\n' for a,b,op in inputs),encoding='ascii')
    return len(inputs)
