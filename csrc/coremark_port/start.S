    .section .text.startup, "ax", @progbits
    .globl _start
    .option norelax
_start:
    la sp, _stack_top
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:
    call main
    li t0, 0x00030000
    sw a0, 0(t0)
3:
    j 3b
