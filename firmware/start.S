    .section .text.startup, "ax", @progbits
    .globl _start
    .option norelax
_start:
    la sp, _stack_top
    la t0, __bss_start
    la t1, __bss_end
clear_bss:
    bgeu t0, t1, run_main
    sw zero, 0(t0)
    addi t0, t0, 4
    j clear_bss
run_main:
    call main
    li t0, 0x00030000
    sw a0, 0(t0)
halt:
    j halt
