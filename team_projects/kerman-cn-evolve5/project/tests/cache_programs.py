from machine_programs import HEAD,END,expect

def cache_programs():
    body=HEAD+'''li s0,0x8000
lw a0,0(s0)
'''+expect('a0',0x11223344)+'''li t0,0x55aa33cc
sw t0,0(s0)
li t0,0x80
sb t0,1(s0)
lb a0,1(s0)
'''+expect('a0',0xffffff80)+'''lbu a0,1(s0)
'''+expect('a0',0x80)+'''li t0,0xbeef
sh t0,2(s0)
lw a0,0(s0)
'''+expect('a0',0xbeef80cc)+'''lh a0,2(s0)
'''+expect('a0',0xffffbeef)+'''lhu a0,2(s0)
'''+expect('a0',0xbeef)+'''lw a1,512(s0)
lw a2,1024(s0)
lw a0,0(s0)
'''+expect('a0',0xbeef80cc)+'''j pass
'''+END
    irq=HEAD+'''li s0,0
la t0,handler
csrw mtvec,t0
li s1,0x8000
lw s4,0(s1)
li t0,128
csrw mie,t0
csrsi mstatus,8
li t1,0x89abcdef
sw t1,0(s1)
lw s5,0(s1)
'''+expect('s5',0x89abcdef)+expect('s0',1)+'''j pass
handler:
addi s0,s0,1
csrwi mie,0
mret
'''+END
    return [dict(name='cache_byte_halfword_write_hit_and_eviction',asm=body,scene=0,irq=0,trap=0,profiles=[(0,0),(2,2),(0,3)]),
            dict(name='cache_irq_during_write_hit',asm=irq,scene=7,irq=1,trap=0,profiles=[(0,3),(2,3)])]
