    .section .text.startup, "ax", @progbits
    .globl _start
    .option norelax
_start:
    la sp, _stack_top
    la t0, trap_entry
    csrw mtvec, t0
    csrr t0, misa
    li t1, 0x40000100
    bne t0, t1, fail
    csrr t0, mstatus
    li t1, 0x1800
    bne t0, t1, fail
    li s6, 0
    li s7, 0
    addi t0, zero, 5
    addi t1, zero, 7
    add t2, t0, t1
    li t3, 12
    bne t2, t3, fail
    addi t2, t2, 1
    addi t2, t2, 1
    li t3, 14
    bne t2, t3, fail
    addi zero, t3, 3
    bne zero, zero, fail
    li t0, 0x80000000
    li t1, -1
    mul t2, t0, t1
    bne t2, t0, fail
    mulh t2, t0, t1
    bnez t2, fail
    mulhsu t2, t0, t1
    bne t2, t0, fail
    mulhu t2, t0, t1
    li t3, 0x7fffffff
    bne t2, t3, fail
    li s2, 0x20001000
    li t0, 0x11223344
    sw t0, 0(s2)
    li t0, 0x80
    sb t0, 1(s2)
    lw t1, 0(s2)
    li t2, 0x11228044
    bne t1, t2, fail
    lb t1, 1(s2)
    li t2, -128
    bne t1, t2, fail
    li t0, 0x8001
    sh t0, 2(s2)
    lh t1, 2(s2)
    li t2, -32767
    bne t1, t2, fail
    lw t1, 0(s2)
    li t2, 0x80018044
    bne t1, t2, fail
    li s0, 2
    la s1, illegal_div
illegal_div:
    .word 0x0220c1b3
    li t0, 1
    bne s6, t0, fail
    li s0, 0x80000007
    li s3, 0
    li s4, 0
    li t0, 0x40002000
    sw zero, 16(t0)
    sw zero, 0(t0)
    sw zero, 4(t0)
    li t1, 300
    sw t1, 8(t0)
    sw zero, 12(t0)
    li t1, 0x80
    csrw mie, t1
    csrsi mstatus, 8
    li t1, 3
    sw t1, 16(t0)
irq_wait:
    addi s3, s3, 1
    addi s4, s4, 1
    beq s7, zero, irq_wait
    csrci mstatus, 8
    csrw mie, zero
    bne s3, s4, fail
    li t0, 1
    bne s7, t0, fail
    li t0, 2
    bne s6, t0, fail
    csrr t0, mip
    andi t0, t0, 0x80
    bnez t0, fail
    li t0, 0x40001000
    li t1, 1
    sw t1, 0(t0)
halt:
    j halt

    .balign 4
trap_entry:
    addi sp, sp, -16
    sw t0, 0(sp)
    sw t1, 4(sp)
    sw t2, 8(sp)
    sw t3, 12(sp)
    csrr t0, mcause
    bne t0, s0, fail
    li t2, 2
    bne t0, t2, timer_handler
    csrr t1, mepc
    bne t1, s1, fail
    addi t1, t1, 4
    csrw mepc, t1
    j restore
timer_handler:
    li t0, 0x40002010
    li t1, 1
    sw t1, 0(t0)
    addi s7, s7, 1
restore:
    addi s6, s6, 1
    lw t0, 0(sp)
    lw t1, 4(sp)
    lw t2, 8(sp)
    lw t3, 12(sp)
    addi sp, sp, 16
    mret
fail:
    li t0, 0x40001000
    li t1, 2
    sw t1, 0(t0)
    j fail
