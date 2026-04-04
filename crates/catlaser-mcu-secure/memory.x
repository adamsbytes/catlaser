/* RP2350 Secure image memory layout.
 *
 * Addresses must match catlaser-common::trustzone constants exactly.
 * The Secure image owns the first portion of flash and SRAM. The NSC
 * veneer region is placed at the end of the Secure flash allocation
 * and marked Non-Secure Callable by the SAU at runtime.
 *
 * The Non-Secure image's linker script starts where these regions end:
 *   NS FLASH: 0x10010100 - 0x101FFFFF
 *   NS RAM:   0x20004000 - 0x20081FFF
 */

MEMORY
{
    FLASH : ORIGIN = 0x10000000, LENGTH = 64K
    NSC   : ORIGIN = 0x10010000, LENGTH = 256
    RAM   : ORIGIN = 0x20000000, LENGTH = 16K
}

SECTIONS {
    /* NSC veneer stubs are placed here by the linker when gateway
     * functions use extern "C-cmse-nonsecure-entry". The section
     * name .gnu.sgstubs is the standard ARM CMSE veneer section. */
    .gnu.sgstubs : ALIGN(32)
    {
        *(.gnu.sgstubs*)
    } > NSC
} INSERT AFTER .text;
