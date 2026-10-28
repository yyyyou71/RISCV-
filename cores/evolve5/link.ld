ENTRY(_start)
MEMORY
{
    ROM (rx) : ORIGIN = 0x00000000, LENGTH = 32K
    RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 32K
}
SECTIONS
{
    .text : { KEEP(*(.text.startup)) *(.text .text.*) } > ROM
    .data : {
        *(.rodata .rodata.* .srodata .srodata.*)
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
    } > RAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(__bss_end <= _stack_top - 8192, "EVOLVE5 leaves less than 8 KiB for stack")
    ASSERT(_start == ORIGIN(ROM), "Entry must be at zero")
    /DISCARD/ : { *(.comment .note .note.* .riscv.attributes .eh_frame*) }
}
