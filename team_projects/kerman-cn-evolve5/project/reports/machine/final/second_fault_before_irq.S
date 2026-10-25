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
li t6,17
bne a0,t6,fail
li t6,29
bne a1,t6,fail
li t6,1
bne s0,t6,fail
j pass
handler:
csrr t0,mcause
li t6,5
bne t0,t6,fail
csrr t0,mepc
la t1,fault
bne t0,t1,fail
csrr t0,mtval
li t6,61440
bne t0,t6,fail
li t6,17
bne a0,t6,fail
li t6,29
bne a1,t6,fail
addi s0,s0,1
csrwi mie,0
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
