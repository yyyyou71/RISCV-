.option norvc
.option norelax
.section .bss
.balign 512
cache_probe_area:
.space 1536
.section .text
.globl cache_probe
cache_probe:
    la t0,cache_probe_area
    li a7,0x40003000
    lw a5,0x114(a7)
    li t1,0x11223344
    sw t1,0(t0)
    li t1,0x55667788
    sw t1,512(t0)
    li t1,0x99aabbcc
    sw t1,1024(t0)
    lw t1,0x114(a7)
    sub t1,t1,a5
    li t2,3
    bne t1,t2,fail1
    lw a2,0x108(a7)
    lw a3,0x10c(a7)
    lw t1,0(t0)
    li t2,0x11223344
    bne t1,t2,fail2
    lw t1,4(t0)
    bnez t1,fail2
    lw t1,512(t0)
    li t2,0x55667788
    bne t1,t2,fail2
    lw t1,0(t0)
    lw t1,1024(t0)
    li t2,0x99aabbcc
    bne t1,t2,fail2
    lw t1,0(t0)
    lw t1,512(t0)
    lw t1,0x108(a7)
    sub t1,t1,a2
    li t2,3
    bne t1,t2,fail3
    lw t1,0x10c(a7)
    sub t1,t1,a3
    li t2,4
    bne t1,t2,fail4
    lw a6,0x110(a7)
    li t1,0x80
    sb t1,513(t0)
    li t1,0xbeef
    sh t1,514(t0)
    lb t1,513(t0)
    li t2,-128
    bne t1,t2,fail5
    lbu t1,513(t0)
    li t2,128
    bne t1,t2,fail5
    lh t1,514(t0)
    li t2,0xffffbeef
    bne t1,t2,fail5
    lhu t1,514(t0)
    li t2,0xbeef
    bne t1,t2,fail5
    lw t1,512(t0)
    li t2,0xbeef8088
    bne t1,t2,fail5
    lw t1,0x110(a7)
    sub t1,t1,a6
    li t2,2
    bne t1,t2,fail6
    lw t1,1024(t0)
    lw t1,0(t0)
    lw t1,512(t0)
    li t2,0xbeef8088
    bne t1,t2,fail7
    li a0,0
    ret
fail1: li a0,1
    ret
fail2: li a0,2
    ret
fail3: li a0,3
    ret
fail4: li a0,4
    ret
fail5: li a0,5
    ret
fail6: li a0,6
    ret
fail7: li a0,7
    ret
