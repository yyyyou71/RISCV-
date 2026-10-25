"""Self-checking assembly. CSR expected values are generated independently in Python."""
import random
HEAD='''.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
'''
END='''pass:
li t0,0xfff0
li t1,1
sw t1,0(t0)
j .
fail:
li t0,0xfff0
li t1,0xdead
sw t1,0(t0)
j .
'''
def expect(reg,value): return f'li t6,{value & 0xffffffff}\nbne {reg},t6,fail\n'

def programs(implementation_id=0x00020501,misa=0x40000100):
    out=[]; rng=random.Random(20260926)
    # Six CSR forms, source=x0 versus source register containing zero, rd=x0.
    values={0x340:0,0x341:0,0x342:0,0x343:0,0x304:0,0x300:0x1800,0x301:misa,0x310:0,0x306:0,0x305:0,0x344:0}
    def warl(addr,value):
        if addr==0x341: return value & 0xfffffffc
        if addr==0x305: return (value & 0xfffffffc) | (1 if value&3==1 else 0)
        if addr==0x304: return value & 0x80
        if addr==0x300: return (value & 0x88)|0x1800
        if addr==0x301: return misa
        if addr in (0x306,0x310,0x344): return 0
        return value & 0xffffffff
    body=HEAD
    for index in range(288):
        addr=list(values)[index%len(values)]; old=values[addr]
        kind=index%6; operation=('csrrw','csrrs','csrrc','csrrwi','csrrsi','csrrci')[kind]
        operand=rng.getrandbits(32) if kind<3 else rng.randrange(32)
        zero_source=index%7==0; rd='zero' if index%5==0 else 'a0'
        if kind<3:
            operand=0 if zero_source else operand
            body+=f'li t0,{operand}\n'; src='zero' if zero_source else 't0'
        else:
            operand=0 if zero_source else operand; src=str(operand)
        body+=f'{operation} {rd},0x{addr:x},{src}\n'
        if rd!='zero': body+=expect(rd,old)
        writes=kind%3==0 or not zero_source and (kind<3 or operand!=0)
        raw=operand if kind%3==0 else old|operand if kind%3==1 else old & ~operand
        if writes: values[addr]=warl(addr,raw)
        body+=f'csrr a1,0x{addr:x}\n'+expect('a1',values[addr])
    for addr,expected in ((0xf11,0),(0xf12,0),(0xf13,implementation_id),(0xf14,0)):
        body+=f'csrrs a0,0x{addr:x},zero\n'+expect('a0',expected)+f'csrrsi zero,0x{addr:x},0\n'
    body+='j pass\n'+END
    out.append(dict(name='csr_six_forms_warl',asm=body,scene=0,irq=0,trap=0,profiles=[(0,0),(1,1),(2,2),(0,3)]))
    body=HEAD+'''csrwi mcountinhibit,5
li t0,0xffffffff
csrw mcycle,t0
li t0,0x12345678
csrw mcycleh,t0
csrr a0,cycle
csrr a1,cycleh
'''+expect('a0',0xffffffff)+expect('a1',0x12345678)+'''li t0,100
csrw minstret,t0
csrr a0,instret
'''+expect('a0',100)+'''csrwi mcountinhibit,0
nop
csrr a0,minstret
'''+expect('a0',101)+'''li t0,500
csrw minstret,t0
csrr a0,minstret
'''+expect('a0',500)+'''wfi
j pass
'''+END
    out.append(dict(name='counters_write_inhibit_wfi',asm=body,scene=0,irq=0,trap=0,profiles=[(0,0),(2,2)]))
    # Each exception returns past a deliberately younger store, which must be squashed.
    faults=[('ecall','ecall',11,0),('ebreak','ebreak',3,'pc'),('illegal','.word 0xffffffff',2,0xffffffff),
            ('unknown_csr','csrrw zero,0x7ff,t0',2,0x7ff29073),
            ('readonly_write','csrrw zero,mvendorid,zero',2,0xf1101073),
            ('readonly_zero_register','csrrs t1,mvendorid,t0',2,0xf112a373),
            ('misaligned_load','lw t1,1(s5)',4,0x8001),('misaligned_store','sw t1,1(s5)',6,0x8001),
            ('load_access','lw t1,0(s6)',5,0xf000),('store_access','sw t1,0(s6)',7,0xf000),
            ('instruction_misaligned','jalr t1,18(zero)',0,18)]
    # Derive faulting instruction tval from assembler for CSR cases with a zero source value.
    faults[3]=('unknown_csr','csrrw zero,0x7ff,t0',2,0x7ff29073)
    faults[5]=('readonly_zero_register','csrrs t1,mvendorid,t0',2,0xf112a373)
    body=HEAD+'la t0,handler\ncsrw mtvec,t0\nli s0,0\nli s5,0x8000\nli s6,0xf000\nsw zero,0(s5)\n'
    for index,(name,insn,cause,tval) in enumerate(faults):
        body+=f'li s1,{cause}\nla s2,fault_{index}\nla s4,resume_{index}\n'
        body+=f'la s3,fault_{index}\n' if tval=='pc' else f'li s3,{tval}\n'
        body+=f'li t0,0\nli t1,0x55\nfault_{index}:\n{insn}\nsw t1,0(s5)\nresume_{index}:\nlw a0,0(s5)\n'+expect('a0',0)
    body+='li s1,1\nli s2,0xf000\nli s3,0xf000\nla s4,resume_fetch\njalr zero,0(s6)\nresume_fetch:\n'
    body+=expect('s0',len(faults)+1)+'j pass\nhandler:\ncsrr t0,mcause\nbne t0,s1,fail\ncsrr t0,mepc\nbne t0,s2,fail\ncsrr t0,mtval\nbne t0,s3,fail\ncsrr t0,mstatus\nandi t0,t0,8\nbnez t0,fail\naddi s0,s0,1\ncsrw mepc,s4\nmret\n'+END
    out.append(dict(name='precise_exceptions_return',asm=body,scene=0,irq=0,trap=len(faults)+1,profiles=[(0,0),(1,1),(2,2),(0,3)]))
    for vectored in (False,True):
        body=HEAD+'li s0,0\nla t0,vector\n'
        if vectored: body+='ori t0,t0,1\n'
        body+='csrw mtvec,t0\ncsrr a0,mip\n'+expect('a0',0x80)
        body+='li t0,0x80\ncsrw mie,t0\n'+expect('s0',0)+'la s1,after_enable\ncsrsi mstatus,8\nafter_enable:\n'+expect('s0',2)
        body+='csrr a0,mstatus\nandi a0,a0,0x88\n'+expect('a0',0x88)+'j pass\n.balign 128\nvector:\n'
        if vectored: body+='j fail\n'+('nop\n'*6)+'j handler\n'
        else: body+='j handler\n'
        body+='handler:\ncsrr t0,mcause\n'+expect('t0',0x80000007)+'csrr t0,mepc\nbne t0,s1,fail\ncsrr t0,mstatus\nandi t0,t0,0x88\n'+expect('t0',0x80)
        body+='addi s0,s0,1\nli t0,2\nbltu s0,t0,leave_irq\ncsrwi mie,0\nleave_irq:\nnop\nnop\nmret\n'+END
        out.append(dict(name='irq_level_retrigger_'+('vectored' if vectored else 'direct'),asm=body,scene=1,irq=2,trap=0,profiles=[(0,0),(2,2)]))
    for name,scene in [('irq_wait_load',2),('irq_wait_store',3),('irq_cancelled_drain',4),('exception_beats_pending_irq',5)]:
        body=HEAD+'la t0,handler\ncsrw mtvec,t0\nli s0,0\nli s1,0x8000\nli s2,0\nli s3,0x987\nli t0,0x80\ncsrw mie,t0\ncsrsi mstatus,8\n'
        if scene==3:
            body+='li s3,0x12345678\nsw s3,0(s1)\naddi s3,s3,1\nlw a0,0(s1)\n'+expect('a0',0x12345678)+expect('s3',0x12345679)
        elif scene==5:
            body+='la s4,resume_fault\nli s6,0xf000\nlw s3,0(s6)\nsw s3,4(s1)\nresume_fault:\n'+expect('s3',0x987)+'lw a0,4(s1)\n'+expect('a0',0)
        else:
            body+='lw s3,0(s1)\naddi s2,s3,1\naddi s2,s2,7\n'+expect('s2',0x1122334c)
        expected=0 if scene==4 else 2 if scene==5 else 1
        body+=expect('s0',expected)+'j pass\nhandler:\ncsrr t0,mcause\n'
        if scene==5:
            body+='bnez s0,irq_after_fault\n'+expect('t0',5)+'csrr t0,mtval\n'+expect('t0',0xf000)+'csrw mepc,s4\nli s0,1\nmret\nirq_after_fault:\n'+expect('s0',1)
        body+=expect('t0',0x80000007)+'addi s0,s0,1\ncsrwi mie,0\nmret\n'+END
        out.append(dict(name=name,asm=body,scene=scene,irq=0 if scene==4 else 1,trap=1 if scene==5 else 0,profiles=[(0,3),(2,3)]))
    body=HEAD+'la t0,handler\ncsrw mtvec,t0\nli t0,0x80\ncsrw mie,t0\ncsrsi mstatus,8\nli s2,1\ncsrci mstatus,8\naddi s2,s2,7\n'
    body+=expect('s2',8)+'csrr a0,mip\n'+expect('a0',0x80)+'csrr a0,mstatus\nandi a0,a0,8\n'+expect('a0',0)+'j pass\nhandler:\nj fail\n'+END
    out.append(dict(name='irq_cancelled_by_older_csr_commit',asm=body,scene=6,irq=0,trap=0,profiles=[(0,3),(2,3)]))
    return out
