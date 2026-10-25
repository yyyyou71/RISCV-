.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
la t0,handler
csrw mtvec,t0
li s0,0
li s1,0xf000
li s2,85
li a0,12
csrr s3,0xfc2
.balign 16
csrr s4,0xfc3
fault:
lw a0,0(s1)
addi s2,zero,99
resume:
mv t5,s5
sub t5,t5,s4
li t6,0
bne t5,t6,fail
li t6,85
bne s2,t6,fail
li t6,12
bne a0,t6,fail
li t6,1
bne s0,t6,fail
j pass
handler:
csrr s5,0xfc3
csrr t0,mcause
li t6,5
bne t0,t6,fail
csrr t0,mepc
la t1,fault
bne t0,t1,fail
csrr t0,mtval
li t6,61440
bne t0,t6,fail
addi s0,s0,1
la t0,resume
csrw mepc,t0
mret
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
