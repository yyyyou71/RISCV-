ENTRY(_start)
MEMORY {
    ROM (rx) : ORIGIN = 0, LENGTH = 32K
    RAM (rw) : ORIGIN = 0x10000, LENGTH = 64K
}
SECTIONS {
    .text : { KEEP(*(.text.startup)) *(.text .text.*) } > ROM
    /* The CPU data bus cannot read the instruction ROM. */
    .data : { *(.rodata .rodata.* .srodata .srodata.*) *(.data .data.* .sdata .sdata.*) } > RAM
    .bss (NOLOAD) : {
        . = ALIGN(4); __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(4); __bss_end = .;
    } > RAM
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(_start == 0, "AI entry must be at address zero")
    ASSERT(__bss_end <= _stack_top - 16K, "AI firmware needs at least 16 KiB stack reserve")
    /DISCARD/ : { *(.comment .note .note.* .riscv.attributes .eh_frame*) }
}
