from machine_programs import HEAD,END,expect

def programs():
    out=[]
    for store in (False,True):
        body=HEAD+'''la t0,handler
csrw mtvec,t0
li s0,0
li s1,0x8000
li a1,29
sw a1,0(s1)
li t0,128
csrw mie,t0
csrsi mstatus,8
fence
.balign 16
csrr t5,mcycle
addi a0,zero,17
'''+('sw a1,0(s1)' if store else 'lw a1,0(s1)')+'''
after_pair:
csrr t5,mstatus
'''+expect('a0',17)+expect('a1',29)+expect('s0',1)+'''j pass
handler:
csrr t0,mcause
'''+expect('t0',0x80000007)+'''csrr t0,mepc
la t1,after_pair
bne t0,t1,fail
'''+expect('a0',17)+expect('a1',29)+'''addi s0,s0,1
csrwi mie,0
mret
'''+END
        out.append(dict(name='irq_second_'+('store' if store else 'load'),asm=body,scene=32 if store else 31,irq=1,trap=0,profiles=[(1,1),(2,2),(0,3)]))
    body=HEAD+'''la t0,handler
csrw mtvec,t0
li s0,0
li s1,0xf000
li a1,29
li t0,128
csrw mie,t0
csrsi mstatus,8
fence
.balign 16
csrr t5,mcycle
addi a0,zero,17
fault:
lw a1,0(s1)
resume:
csrr t5,mstatus
'''+expect('a0',17)+expect('a1',29)+expect('s0',1)+'''j pass
handler:
csrr t0,mcause
'''+expect('t0',5)+'''csrr t0,mepc
la t1,fault
bne t0,t1,fail
csrr t0,mtval
'''+expect('t0',0xf000)+expect('a0',17)+expect('a1',29)+'''addi s0,s0,1
csrwi mie,0
la t0,resume
csrw mepc,t0
mret
'''+END
    out.append(dict(name='second_fault_before_irq',asm=body,scene=33,irq=0,trap=1,profiles=[(1,1),(2,2),(0,3)]))
    return out

def extend(source):
    marker='if(scene==21 && !started'
    assert source.count(marker)==1
    return source.replace(marker,'''if(scene>=31 && scene<=33 && !started && dv && !dr && dut.memory_in_second)begin
                started=1;irq_timer<=1;
            end else if(scene==21 && !started''')
