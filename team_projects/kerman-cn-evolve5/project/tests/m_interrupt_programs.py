"""Timer interrupts before and during a long EX instruction must drain it once."""
from machine_programs import HEAD,END,expect

def m_interrupt_programs(dual=False):
    cases=[]
    for scene,op,a,b,result in [(17,'mul',7,9,63),(18,'divu',0x80000000,7,0x12492492),
                               (19,'mulh',0x80000000,0xffffffff,0),
                               (20,'div',0x80000001,7,0xedb6db6e)]:
        body=HEAD+'''la t0,handler
csrw mtvec,t0
li s1,0
li t0,128
csrw mie,t0
csrsi mstatus,8
'''+f'li a0,{a}\nli a1,{b}\n{op} a2,a0,a1\nafter_m:\n'
        # Keep these legacy M probes at a fixed single-instruction boundary;
        # paired-boundary IRQ behavior is exercised by dual_machine_programs.
        if dual:body+='fence\n'
        body+=expect('a2',result)+expect('s1',1)
        # Exercise a fresh operation after MRET; no stale response may survive.
        body+='li a0,11\nli a1,13\nmul a2,a0,a1\n'+expect('a2',143)+'j pass\n'
        body+='''handler:
csrr t0,mcause
li t1,0x80000007
bne t0,t1,fail
csrr t0,mepc
la t1,after_m
bne t0,t1,fail
addi s1,s1,1
csrwi mie,0
mret
'''+END
        cases.append(dict(name=f'm_irq_scene{scene}_{op}',asm=body,scene=scene,irq=1,trap=0,
                          profiles=[(0,0),(1,1),(2,2),(0,3)]))
    return cases

def inject_m_irq(tb):
    original='if(scene==6 && !started && dut.x_valid'
    insert='''if(!started && ((scene==17 && dut.m_extension.unit.state==1) ||
                (scene==18 && dut.m_extension.unit.state==3 && dut.m_extension.unit.steps==16) ||
                (scene==19 && dut.x_valid && dut.x_mop && !dut.md_issued) ||
                (scene==20 && dut.m_extension.unit.state==3 && dut.m_extension.unit.steps==1))) begin
                started=1; irq_timer<=1;
            end else if(scene==6 && !started && dut.x_valid'''
    assert tb.count(original)==1
    return tb.replace(original,insert)
