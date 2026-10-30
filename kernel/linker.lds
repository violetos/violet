ENTRY(kernel_entry)

PHDRS
{
    rodata  PT_LOAD  FILEHDR  PHDRS  FLAGS(1 << 2);              /* R-- */
    text    PT_LOAD                  FLAGS((1 << 0) | (1 << 2)); /* R-X */
    data    PT_LOAD                  FLAGS((1 << 1) | (1 << 2)); /* RW- */
}

SECTIONS
{
    . = 0xffffffff80000000;

    __rodata_start = .;

    . += SIZEOF_HEADERS;

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.data.rel.ro .data.rel.ro.*)
        *(.got .got.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    PROVIDE(__rodata_end = .);

    __text_start = .;

    .text : ALIGN(16) {
        *(.text .text.*)
        *(.plt .plt.* .iplt)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    PROVIDE(__text_end = .);

    __data_start = .;

    .data : ALIGN(16) {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))

        *(.data .data.*)
        *(.sdata .sdata.* .sdata2 .sdata2.*)
    } :data

    PROVIDE(__data_end = .);
    PROVIDE(__bss_start = .);

    .bss (NOLOAD) : ALIGN(16) {
        *(.sbss .sbss.* .scommon)
        *(.bss .bss.*)
        *(COMMON)
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    PROVIDE(__bss_end = .);

    __kernel_end = .;

    /DISCARD/ : {
        *(.eh_frame .eh_frame.*)
        *(.eh_frame_hdr)
        *(.gcc_except_table .gcc_except_table.*)
        *(.ARM.exidx .ARM.exidx.*)
        *(.ARM.extab .ARM.extab.*)
        *(.ARM.attributes)
        *(.riscv.attributes)
        *(.note .note.*)
        *(.comment)
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.hash)
        *(.gnu.hash)
    }
}
