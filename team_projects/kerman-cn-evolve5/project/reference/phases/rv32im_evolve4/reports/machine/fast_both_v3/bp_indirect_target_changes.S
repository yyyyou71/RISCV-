.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
li s0,0
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
li t6,48
bne s1,t6,fail
j pass
target_a:
li a0,1
ret
target_b:
li a0,2
ret
pass:
li t0,0xfff0
li t1,1
sw t1,0(t0)
j .
fail:
li t0,0xfff0
li t1,0xdead
sw t1,0(t0)
j .
