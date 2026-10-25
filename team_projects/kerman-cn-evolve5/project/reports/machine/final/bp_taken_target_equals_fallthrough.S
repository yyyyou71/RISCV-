.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
li s0,16
li s1,0
loop:
beq zero,zero,next
next:
addi s1,s1,1
addi s0,s0,-1
bnez s0,loop
li t6,16
bne s1,t6,fail
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
