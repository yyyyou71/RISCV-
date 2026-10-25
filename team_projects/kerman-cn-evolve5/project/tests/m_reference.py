"""Independent architectural M semantics using Python unbounded arithmetic."""
from reference import Model,MASK,FIELDS
NAMES=('mul','mulh','mulhsu','mulhu','div','divu','rem','remu')
def signed(x): return x-(1<<32) if x&0x80000000 else x
def result(op,a,b):
    a&=MASK; b&=MASK
    if op==0: return a*b&MASK
    if op==1: return (signed(a)*signed(b)>>32)&MASK
    if op==2: return (signed(a)*b>>32)&MASK
    if op==3: return (a*b>>32)&MASK
    if b==0: return a if op in (6,7) else MASK
    if op in (5,7): return (a//b if op==5 else a%b)&MASK
    x,y=signed(a),signed(b)
    q=abs(x)//abs(y)
    if (x<0)!=(y<0): q=-q
    return (q if op==4 else x-q*y)&MASK
class MModel(Model):
    def step(self):
        if self.pc&3 or self.pc>=0xf000: return super().step()
        insn=self.word(self.pc)
        if insn&127!=0x33 or insn>>25!=1: return super().step()
        op=insn>>12&7; rd=insn>>7&31; rs1=insn>>15&31; rs2=insn>>20&31
        value=result(op,self.reg[rs1],self.reg[rs2])
        rec=dict.fromkeys(FIELDS,0); rec.update(pc=self.pc,insn=insn,next_pc=(self.pc+4)&MASK)
        if rd: self.reg[rd]=value; rec.update(rd_we=1,rd=rd,rd_data=value)
        self.reg[0]=0; self.pc=rec['next_pc']; self.coverage[NAMES[op]]+=1
        return rec
