ENTRY(_start)

SECTIONS
{
    . = RAM_BASE + BOOT_OFFSET;
    .text : { KEEP(*(.text.start)) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) }
    .data : { *(.data .data.*) *(.sdata .sdata.*) }
    .bss (NOLOAD) : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) }
    __stack_top = RAM_BASE + 256K;
    ASSERT(. <= __stack_top - 16K, "benchmark leaves less than 16 KiB for the stack")
}
