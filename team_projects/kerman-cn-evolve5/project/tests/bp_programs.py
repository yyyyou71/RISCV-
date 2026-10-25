from machine_programs import HEAD,END,expect
def prediction_programs():
    result=[]
    def add(name,body):
        result.append(dict(name=name,asm=HEAD+body+END,scene=0,irq=0,trap=0,profiles=[(0,0),(2,2),(0,3)]))
    add('bp_taken_to_not_taken_side_effects','''li s0,12
li s1,1
li s2,0
li s3,0x8000
li s4,0x55
j condition
.balign 128
condition:
bnez s1,taken
j finish
taken:
sw s4,0(s3)
csrw mscratch,s4
addi s2,s2,1
addi s0,s0,-1
bnez s0,condition
li s1,0
sw zero,0(s3)
csrw mscratch,zero
j condition
finish:
'''+expect('s2',12)+'''lw a0,0(s3)
'''+expect('a0',0)+'''csrr a0,mscratch
'''+expect('a0',0)+'j pass\n')
    add('bp_indirect_target_changes','''li s0,0
li s1,0
li s2,32
loop:
andi t0,s0,1
bnez t0,select_b
la t1,target_a
j callsite
select_b:
la t1,target_b
callsite:
jalr ra,0(t1)
add s1,s1,a0
addi s0,s0,1
bltu s0,s2,loop
'''+expect('s1',48)+'''j pass
target_a:
li a0,1
ret
target_b:
li a0,2
ret
''')
    add('bp_full_tag_alias','''li s0,16
li s1,1
li s2,0
j at_a
.org 0x400
at_a:
beq s1,s1,a_taken
j fail
a_taken:
addi s2,s2,1
j at_b
.org 0x480
at_b:
beq s1,zero,fail
addi s0,s0,-1
bnez s0,at_a
'''+expect('s2',16)+'j pass\n')
    add('bp_taken_target_equals_fallthrough','''li s0,16
li s1,0
loop:
beq zero,zero,next
next:
addi s1,s1,1
addi s0,s0,-1
bnez s0,loop
'''+expect('s1',16)+'j pass\n')
    return result
