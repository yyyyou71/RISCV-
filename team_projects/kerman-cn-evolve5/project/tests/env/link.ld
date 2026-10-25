OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0;
  .text : { *(.text.init) *(.text .text.*) }
  ASSERT(. <= 0x4000, "Test text exceeds instruction allocation")
  . = 0x4000;
  .data : { *(.data .data.*) *(.sdata .sdata.*) *(.rodata .rodata.*) }
  .bss : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) }
  ASSERT(. <= 0xe000, "Test data exceeds RAM")
  /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
