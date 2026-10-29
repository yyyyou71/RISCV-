ENTRY(_start)
MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    RAM (rw)  : ORIGIN = 0x00010000, LENGTH = 64K
}
SECTIONS
{
    .text : {
        KEEP(*(.text.startup))
        *(.text .text.*)
    } > ROM

    /* CPU 的数据总线不能读取指令 ROM，常量和字符串也放 RAM。 */
    .data : {
        *(.rodata .rodata.* .srodata .srodata.*)
        *(.data .data.* .sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
    /* 预留 8 KiB 栈空间；越界时让链接失败，而不是静默覆盖数据。 */
    ASSERT(__bss_end <= _stack_top - 8K, "CoreMark RAM leaves less than 8 KiB for stack")
    ASSERT(_start == ORIGIN(ROM), "Entry must be at address zero")
    /DISCARD/ : { *(.comment .note .note.* .eh_frame .eh_frame.* .riscv.attributes) }
}
