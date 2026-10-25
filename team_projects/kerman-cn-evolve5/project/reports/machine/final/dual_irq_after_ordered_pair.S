.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
la t0,handler
csrw mtvec,t0
li s0,0
li t0,128
csrw mie,t0
csrsi mstatus,8
.balign 16
csrr s4,0xfc3
pair_start:
addi a0,zero,17
addi a1,zero,29
after_pair:
csrr t5,0xfc3
sub t5,t5,s4
li t6,1
bne t5,t6,fail
li t6,17
bne a0,t6,fail
li t6,29
bne a1,t6,fail
li t6,1
bne s0,t6,fail
j pass
handler:
csrr t0,mcause
li t1,0x80000007
bne t0,t1,fail
csrr t0,mepc
la t1,after_pair
bne t0,t1,fail
li t1,17
bne a0,t1,fail
li t1,29
bne a1,t1,fail
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
