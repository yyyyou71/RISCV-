"""Behavioral predictor oracle: sparse tables and a Python list return stack."""
import random

class Predictor:
    def __init__(self,bits,pht,ras,gs):
        self.bits=bits;self.pht=pht;self.ras_depth=ras;self.gs=gs;self.reset()
    def reset(self): self.btb={};self.counters={};self.history=0;self.stack=[]
    def query(self,pc,insn,error,rst=False):
        op=insn&127;f3=insn>>12&7;rd=insn>>7&31;rs=insn>>15&31
        cond=op==0x63 and f3 in (0,1,4,5,6,7)
        control=cond or op==0x6f or op==0x67 and f3==0
        slot=(pc>>2)&((1<<self.bits)-1); entry=self.btb.get(slot)
        hit=bool(not rst and not error and control and entry and entry[0]==pc>>(self.bits+2))
        index=((pc>>2)^self.history)&((1<<self.pht)-1) if self.gs else 0
        direction=self.counters.get(index,1)>=2 if self.gs else bool(entry and entry[2]>=2)
        rh=bool(not rst and not error and op==0x67 and f3==0 and insn>>20==0 and rs in (1,5) and (rd not in (1,5) or rd!=rs) and self.stack)
        taken=rh or hit and (not cond or direction)
        npc=self.stack[-1] if rh else entry[1] if taken else (pc+4)&0xffffffff
        return [int(hit or rh),int(taken),npc,index,int(rh)]
    def update(self,rst,flush,valid,pc,insn,conditional,taken,target,index):
        if rst: self.reset();return
        if valid:
            slot=(pc>>2)&((1<<self.bits)-1);tag=pc>>(self.bits+2);old=self.btb.get(slot)
            same=old is not None and old[0]==tag
            if taken:
                self.btb[slot]=(tag,target&0xfffffffc,3 if not conditional else min(3,old[2]+1) if same else 2)
            elif conditional and same: self.btb[slot]=(tag,old[1],max(0,old[2]-1))
            if self.gs and conditional:
                self.counters[index]=min(3,self.counters.get(index,1)+1) if taken else max(0,self.counters.get(index,2)-1)
        if flush: self.history=0;self.stack=[];return
        if valid and self.gs and conditional: self.history=((self.history<<1)|taken)&((1<<self.pht)-1)
        if valid and self.ras_depth:
            op=insn&127;rd=insn>>7&31;rs=insn>>15&31;jalr=op==0x67 and (insn>>12&7)==0
            pop=jalr and rs in (1,5) and (rd not in (1,5) or rd!=rs)
            push=rd in (1,5) and (op==0x6f or jalr)
            if pop and self.stack:self.stack.pop()
            if push:
                self.stack.append((pc+4)&0xffffffff)
                self.stack=self.stack[-self.ras_depth:]

def vectors(bits,pht,depth,gs):
    m=Predictor(bits,pht,depth,gs);rng=random.Random(20261019+bits+pht+depth)
    pending=[];out=[]
    ops=[0x00000063,0x00001063,0x00004063,0x00007063,0x000000ef,0x000002ef,
         0x00008067,0x00028067,0x000080e7,0x000082e7,0x000280e7,0x00010067,0x00000013,0x00002063]
    for n in range(9000):
        rst=int(n in (0,337,2003,7781));flush=int(not rst and n%211==0)
        pc=4*rng.randrange(512);insn=rng.choice(ops);error=int(rng.randrange(17)==0)
        # Force overflow, underflow, x5 and pop+push before mixed traffic.
        if 1<=n<=40: pc=0x100;insn=0x00008067;error=0
        before=m.query(pc,insn,error,bool(rst))
        valid=int(bool(pending) and rng.randrange(4)!=0 and not flush and not rst)
        if 1<=n<=20:
            valid=1;upc=0x400+4*n;ui=0x000000ef;cond=0;taken=1;target=0x100;idx=0
        elif 21<=n<=40:
            valid=1;upc=0x100;ui=0x00008067;cond=0;taken=1;target=0x800;idx=0
        elif valid: upc,ui,cond,taken,target,idx=pending.pop(0)
        else: upc=ui=cond=taken=target=idx=0
        inputs=[rst,flush,pc,insn,error,valid,upc,ui,cond,taken,target,idx]
        m.update(rst,flush,valid,upc,ui,cond,taken,target,idx)
        after=m.query(pc,insn,error,bool(rst))
        out.append(inputs+before+after)
        if rst or flush: pending=[]
        elif not error and len(pending)<16:
            op=insn&127;cond=int(op==0x63);taken=rng.randrange(2) if cond else 1
            if op in (0x63,0x6f,0x67) and (op!=0x63 or (insn>>12&7) in (0,1,4,5,6,7)):
                pending.append((pc,insn,cond,taken,4*rng.randrange(1024),before[3]))
    return out
