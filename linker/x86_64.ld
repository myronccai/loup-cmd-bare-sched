/* The x86_64 images (scheduler and self-test) for `qemu-system-x86_64 -kernel`.
 *
 * QEMU loads the ELF at its link address, 1 MiB, and enters it at the
 * address in the PVH note (.note.Xen, its own PT_NOTE segment). The boot
 * page tables get three page-aligned pages of their own (__boot_pml4,
 * __boot_pdpt, __boot_pd); the boot stack, which becomes the idle task's
 * stack, follows .bss. Task stacks are ordinary .bss: the kernel reserves
 * them with makeBufferU64.
 */
ENTRY(_start)

PHDRS {
    image PT_LOAD FLAGS(7);    /* read, write, execute: one segment */
    note  PT_NOTE FLAGS(4);
}

SECTIONS {
    . = 0x100000;

    .boot : { KEEP(*(.text.boot)) } :image

    .note.Xen : { KEEP(*(.note.Xen)) } :image :note

    .text   : { *(.text .text.*) }     :image
    .rodata : { *(.rodata .rodata.*) } :image
    .data   : { *(.data .data.*) }     :image
    .idt    : ALIGN(4096) { KEEP(*(.idt)) } :image

    .bss : {
        *(.bss .bss.*)
        . = ALIGN(4096);
        __boot_pml4 = .;
        . = . + 4096;
        __boot_pdpt = .;
        . = . + 4096;
        __boot_pd = .;
        . = . + 4096;
        . = . + 65536;
        __stack_top = .;
    } :image
}
