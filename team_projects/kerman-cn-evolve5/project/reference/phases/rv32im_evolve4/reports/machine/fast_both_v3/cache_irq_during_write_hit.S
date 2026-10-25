.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
li s0,0
la t0,handler
csrw mtvec,t0
li s1,0x8000
lw s4,0(s1)
li t0,128
csrw mie,t0
csrsi mstatus,8
li t1,0x89abcdef
sw t1,0(s1)
lw s5,0(s1)
li t6,2309737967
bne s5,t6,fail
li t6,1
bne s0,t6,fail
j pass
handler:
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
