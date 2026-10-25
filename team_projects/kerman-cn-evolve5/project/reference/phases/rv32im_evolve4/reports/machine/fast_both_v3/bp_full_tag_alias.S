.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
li s0,16
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
li t6,16
bne s2,t6,fail
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
