.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
li s0,12
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
li t6,12
bne s2,t6,fail
lw a0,0(s3)
li t6,0
bne a0,t6,fail
csrr a0,mscratch
li t6,0
bne a0,t6,fail
j pass
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
