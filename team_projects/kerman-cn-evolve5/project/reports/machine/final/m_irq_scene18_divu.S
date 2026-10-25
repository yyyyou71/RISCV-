.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
la t0,handler
csrw mtvec,t0
li s1,0
li t0,128
csrw mie,t0
csrsi mstatus,8
li a0,2147483648
li a1,7
divu a2,a0,a1
after_m:
fence
li t6,306783378
bne a2,t6,fail
li t6,1
bne s1,t6,fail
li a0,11
li a1,13
mul a2,a0,a1
li t6,143
bne a2,t6,fail
j pass
handler:
csrr t0,mcause
li t1,0x80000007
bne t0,t1,fail
csrr t0,mepc
la t1,after_m
bne t0,t1,fail
addi s1,s1,1
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
