ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    RAM (rwx) : ORIGIN = 0x00001000, LENGTH = 60K
}

SECTIONS
{
    .text : { *(.text .text.*) } > ROM

    /* ★ 把 .rodata/.data/.sdata 全部合并成一个输出段 .data
          → 只需要导出【一个】数据文件 */
    .data : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    /* 无初值的：RAM 本来就是 0，天然正确，不用导出 */
    .bss : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) } > RAM

    _stack_top = 0x00010000;

    /DISCARD/ : { *(.comment) *(.note .note.*) *(.riscv.attributes) }
}
