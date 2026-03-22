/*
 * Minimal .reloc section stub for LoongArch64 PE/COFF EFI binaries.
 * Same as AevOS: objcopy needs valid BaseRelocationTable.
 */
	.section .reloc, "a"
	.align 2
	.long	0	/* VirtualAddress (dummy) */
	.long	8	/* SizeOfBlock (header-only, zero relocations) */
