.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
la t0,handler
csrw mtvec,t0
li t0,0x80
csrw mie,t0
csrsi mstatus,8
li s2,1
csrci mstatus,8
addi s2,s2,7
li t6,8
bne s2,t6,fail
csrr a0,mip
li t6,128
bne a0,t6,fail
csrr a0,mstatus
andi a0,a0,8
li t6,0
bne a0,t6,fail
j pass
handler:
j fail
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
