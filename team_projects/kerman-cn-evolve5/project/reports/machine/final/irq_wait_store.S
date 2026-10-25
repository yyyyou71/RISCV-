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
li s3,0x12345678
sw s3,0(s1)
addi s3,s3,1
lw a0,0(s1)
li t6,305419896
bne a0,t6,fail
li t6,305419897
bne s3,t6,fail
li t6,1
bne s0,t6,fail
j pass
handler:
csrr t0,mcause
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
