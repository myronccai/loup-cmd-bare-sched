/* The aarch64 images (scheduler and self-test) for
 * `qemu-system-aarch64 -M virt -kernel`.
 *
 * QEMU's virt machine has RAM at 0x40000000 and loads a bare ELF at its
 * link address; 0x40080000 leaves the first 512 KiB to QEMU's device tree.
 * .text.boot (_start) comes first; the exception vector table needs 2 KiB
 * alignment for VBAR_EL1. The boot stack, which becomes the idle task's
 * stack, follows .bss.
 */
ENTRY(_start)

PHDRS {
    image PT_LOAD FLAGS(7);    /* read, write, execute: one segment */
}

SECTIONS {
    . = 0x40080000;

    .text.boot : { KEEP(*(.text.boot)) }  :image
    .vectors   : ALIGN(2048) { KEEP(*(.text.vectors)) } :image
    .text      : { *(.text .text.*) }     :image
    .rodata    : { *(.rodata .rodata.*) } :image
    .data      : { *(.data .data.*) }     :image

    .bss : {
        *(.bss .bss.*)
        . = ALIGN(16);
        . = . + 65536;
        __stack_top = .;
    } :image
}
