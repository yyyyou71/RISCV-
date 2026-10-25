.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
la t0,handler
csrw mtvec,t0
li s0,0
li s1,0x8000
li s2,0
li s3,0x987
li t0,0x80
csrw mie,t0
csrsi mstatus,8
la s4,resume_fault
li s6,0xf000
lw s3,0(s6)
sw s3,4(s1)
resume_fault:
li t6,2439
bne s3,t6,fail
lw a0,4(s1)
li t6,0
bne a0,t6,fail
li t6,2
bne s0,t6,fail
j pass
handler:
csrr t0,mcause
bnez s0,irq_after_fault
li t6,5
bne t0,t6,fail
csrr t0,mtval
li t6,61440
bne t0,t6,fail
csrw mepc,s4
li s0,1
mret
irq_after_fault:
li t6,1
bne s0,t6,fail
li t6,2147483655
bne t0,t6,fail
addi s0,s0,1
csrwi mie,0
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
