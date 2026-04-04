/* RP2350 Non-Secure image memory layout.
 *
 * Addresses must match catlaser-common::trustzone constants exactly.
 * The Secure image owns the first portion of flash and SRAM; this
 * image starts where those regions end.
 *
 *   Secure FLASH: 0x10000000 - 0x1000FFFF  (64K)
 *   NSC veneers:  0x10010000 - 0x100100FF  (256B)
 *   NS FLASH:     0x10010100 - 0x101FFFFF  (this image)
 *
 *   Secure RAM:   0x20000000 - 0x20003FFF  (16K)
 *   NS RAM:       0x20004000 - 0x20081FFF  (this image)
 */

MEMORY
{
    FLASH : ORIGIN = 0x10010100, LENGTH = 0x001EFF00
    RAM   : ORIGIN = 0x20004000, LENGTH = 0x0007E000
}
