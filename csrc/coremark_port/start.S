/* CoreMark 裸机入口。数据镜像由 TB 预加载，启动代码负责清 BSS。 */
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
    /* 原版 CoreMark main 返回 0；CRC 由主机脚本独立核验。 */
    li t0, 0x00030000
    sw a0, 0(t0)
3:
    j 3b
