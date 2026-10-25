.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
li s0,0
la t0,vector
ori t0,t0,1
csrw mtvec,t0
csrr a0,mip
li t6,128
bne a0,t6,fail
li t0,0x80
csrw mie,t0
li t6,0
bne s0,t6,fail
la s1,after_enable
csrsi mstatus,8
after_enable:
li t6,2
bne s0,t6,fail
csrr a0,mstatus
andi a0,a0,0x88
li t6,136
bne a0,t6,fail
j pass
.balign 128
vector:
j fail
nop
nop
nop
nop
nop
nop
j handler
handler:
csrr t0,mcause
li t6,2147483655
bne t0,t6,fail
csrr t0,mepc
bne t0,s1,fail
csrr t0,mstatus
andi t0,t0,0x88
li t6,128
bne t0,t6,fail
addi s0,s0,1
li t0,2
bltu s0,t0,leave_irq
csrwi mie,0
leave_irq:
nop
nop
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
