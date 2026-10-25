.option norvc
.option norelax
.section .text
.globl _start
_start:
li sp,0xe000
la t0,handler
csrw mtvec,t0
li s0,0
li s5,0x8000
li s6,0xf000
sw zero,0(s5)
li s1,11
la s2,fault_0
la s4,resume_0
li s3,0
li t0,0
li t1,0x55
fault_0:
ecall
sw t1,0(s5)
resume_0:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,3
la s2,fault_1
la s4,resume_1
la s3,fault_1
li t0,0
li t1,0x55
fault_1:
ebreak
sw t1,0(s5)
resume_1:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,2
la s2,fault_2
la s4,resume_2
li s3,4294967295
li t0,0
li t1,0x55
fault_2:
.word 0xffffffff
sw t1,0(s5)
resume_2:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,2
la s2,fault_3
la s4,resume_3
li s3,2146603123
li t0,0
li t1,0x55
fault_3:
csrrw zero,0x7ff,t0
sw t1,0(s5)
resume_3:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,2
la s2,fault_4
la s4,resume_4
li s3,4044361843
li t0,0
li t1,0x55
fault_4:
csrrw zero,mvendorid,zero
sw t1,0(s5)
resume_4:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,2
la s2,fault_5
la s4,resume_5
li s3,4044530547
li t0,0
li t1,0x55
fault_5:
csrrs t1,mvendorid,t0
sw t1,0(s5)
resume_5:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,4
la s2,fault_6
la s4,resume_6
li s3,32769
li t0,0
li t1,0x55
fault_6:
lw t1,1(s5)
sw t1,0(s5)
resume_6:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,6
la s2,fault_7
la s4,resume_7
li s3,32769
li t0,0
li t1,0x55
fault_7:
sw t1,1(s5)
sw t1,0(s5)
resume_7:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,5
la s2,fault_8
la s4,resume_8
li s3,61440
li t0,0
li t1,0x55
fault_8:
lw t1,0(s6)
sw t1,0(s5)
resume_8:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,7
la s2,fault_9
la s4,resume_9
li s3,61440
li t0,0
li t1,0x55
fault_9:
sw t1,0(s6)
sw t1,0(s5)
resume_9:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,0
la s2,fault_10
la s4,resume_10
li s3,18
li t0,0
li t1,0x55
fault_10:
jalr t1,18(zero)
sw t1,0(s5)
resume_10:
lw a0,0(s5)
li t6,0
bne a0,t6,fail
li s1,1
li s2,0xf000
li s3,0xf000
la s4,resume_fetch
jalr zero,0(s6)
resume_fetch:
li t6,12
bne s0,t6,fail
j pass
handler:
csrr t0,mcause
bne t0,s1,fail
csrr t0,mepc
bne t0,s2,fail
csrr t0,mtval
bne t0,s3,fail
csrr t0,mstatus
andi t0,t0,8
bnez t0,fail
addi s0,s0,1
csrw mepc,s4
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
