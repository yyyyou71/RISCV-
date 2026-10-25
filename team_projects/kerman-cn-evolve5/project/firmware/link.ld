OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 32K
}
SECTIONS {
    .text : ALIGN(4) {
        KEEP(*(.text.boot))
        *(.text .text.*)
        . = ALIGN(4);
    } > ROM = 0x13000000
    .rodata : ALIGN(4) {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > ROM
    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM AT > ROM
    __data_load_start = LOADADDR(.data);
    __rom_image_end = LOADADDR(.data) + SIZEOF(.data);
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    __global_pointer$ = ORIGIN(RAM) + 0x800;
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    __stack_bottom = __stack_top - 4096;
    ASSERT(__bss_end <= __stack_bottom, "RAM sections overlap reserved 4 KiB stack")
    ASSERT(__rom_image_end <= ORIGIN(ROM) + LENGTH(ROM), "ROM overflow")
    /DISCARD/ : { *(.comment) *(.eh_frame*) *(.note*) }
}
