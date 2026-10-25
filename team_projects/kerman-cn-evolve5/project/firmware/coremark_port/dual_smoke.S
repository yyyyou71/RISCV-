.option norvc
.option norelax
.section .text.dual_smoke_loop,"ax",@progbits
.globl dual_smoke_loop
.type dual_smoke_loop,@function
dual_smoke_loop:
    mv t0,a0
    mv t1,a1
    li a0,0
    li a1,0
    li a2,0
    li a3,0
    li a4,0
    li a5,0
    li a6,0
    li a7,0
.balign 16
    csrr t2,0xfc3
    csrr t3,mcycle
    csrr t4,minstret
    nop
1:
.rept 4
    addi a0,a0,1
    addi a1,a1,2
    addi a2,a2,3
    addi a3,a3,4
    addi a4,a4,5
    addi a5,a5,6
    addi a6,a6,7
    addi a7,a7,8
.endr
    addi t0,t0,-1
    bnez t0,1b
    csrr t5,minstret
    csrr t6,mcycle
    csrr t0,0xfc3
    sub t5,t5,t4
    sub t6,t6,t3
    sub t0,t0,t2
    sw a0,0(t1)
    sw a1,4(t1)
    sw a2,8(t1)
    sw a3,12(t1)
    sw a4,16(t1)
    sw a5,20(t1)
    sw a6,24(t1)
    sw a7,28(t1)
    sw t6,32(t1)
    sw t5,36(t1)
    sw t0,40(t1)
    ret
.size dual_smoke_loop,.-dual_smoke_loop
