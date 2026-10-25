import random
from pathlib import Path

def vectors(path):
    slots={}; rows=[]; categories=set()
    def query(pc,insn,error):
        op=insn&127; f3=(insn>>12)&7
        cond=op==0x63 and f3 in (0,1,4,5,6,7)
        control=cond or op==0x6f or (op==0x67 and f3==0)
        entry=slots.get((pc>>2)&3)
        hit=not error and control and entry is not None and entry[0]==pc>>4
        taken=hit and (not cond or entry[2]>=2)
        return int(hit),int(taken),entry[1] if taken else (pc+4)&0xffffffff
    def add(category,pc=0x100,insn=0x00000463,error=0,valid=0,upc=0x100,target=0x200,taken=1,conditional=1,reset=0):
        categories.add(category)
        if reset: slots.clear()
        before=(0,0,(pc+4)&0xffffffff) if reset else query(pc,insn,error)
        if not reset and valid:
            index=(upc>>2)&3; entry=slots.get(index); matching=entry is not None and entry[0]==upc>>4
            if taken:
                counter=3 if not conditional else min(entry[2]+1,3) if matching else 2
                slots[index]=(upc>>4,target&0xfffffffc,counter)
            elif conditional and matching:
                slots[index]=(entry[0],entry[1],max(entry[2]-1,0))
        after=(0,0,(pc+4)&0xffffffff) if reset else query(pc,insn,error)
        rows.append((reset,pc,insn,error,valid,upc,target,taken,conditional,*before,*after))
    add('reset',reset=1); add('cold')
    for taken in (1,1,1,0,0,0,0,1,1,1): add('saturation',valid=1,taken=taken)
    add('collision',valid=1,upc=0x110,target=0x300,conditional=0)
    add('collision',pc=0x110,insn=0x6f)
    add('high_tag',valid=1,upc=0x80000110,target=0x400,conditional=0)
    add('high_tag',pc=0x110,insn=0x6f)
    add('high_tag',pc=0x80000110,insn=0x6f)
    for insn in (0x13,0x30200073,0x00002063,0x00001067):
        add('noncontrol_gating',pc=0x80000110,insn=insn)
    add('fetch_error_gating',pc=0x80000110,insn=0x6f,error=1)
    add('target_change',pc=0x80000110,insn=0x67,valid=1,upc=0x80000110,target=0x600,conditional=0)
    add('reset_after_training',pc=0x80000110,reset=1)
    rng=random.Random(20260928)
    pcs=[0x100,0x104,0x108,0x10c,0x110,0x80000100,0xfffffffc]
    for index in range(4096):
        add('random',pc=rng.choice(pcs),insn=rng.choice([0x00000463,0x00001463,0x6f,0x67,0x13,0x30200073,0x2063]),
            error=int(rng.randrange(12)==0),valid=int(rng.randrange(4)!=0),upc=rng.choice(pcs),
            target=rng.getrandbits(30)<<2,taken=rng.randrange(2),conditional=int(rng.randrange(4)!=0),reset=int(index%257==0))
    path.write_text('\n'.join(' '.join(f'{x:08x}' for x in row) for row in rows)+'\n',encoding='ascii')
    return {'vectors':len(rows),'categories':sorted(categories),'index_bits':2}
