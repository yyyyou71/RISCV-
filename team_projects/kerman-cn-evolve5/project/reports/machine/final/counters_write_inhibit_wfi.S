.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
csrwi mcountinhibit,5
li t0,0xffffffff
csrw mcycle,t0
li t0,0x12345678
csrw mcycleh,t0
csrr a0,cycle
csrr a1,cycleh
li t6,4294967295
bne a0,t6,fail
li t6,305419896
bne a1,t6,fail
li t0,100
csrw minstret,t0
csrr a0,instret
li t6,100
bne a0,t6,fail
csrwi mcountinhibit,0
nop
csrr a0,minstret
li t6,101
bne a0,t6,fail
li t0,500
csrw minstret,t0
csrr a0,minstret
li t6,500
bne a0,t6,fail
wfi
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
