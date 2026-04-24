"""Compute storage: SPI NAND + QSPI boot flash + microSD.

Per ARCHITECTURE.md:
    - 2 MB QSPI flash on the SiP's QSPI boot interface (FSBL/SPL/uboot)
    - 256 MB SPI NAND, 8-pin SOIC (no BGA), holds Buildroot rootfs
      (read-only) + RKNN model files + small writable journal partition
      for SQLite and config
    - microSD slot (ship 2 GB, user-expandable) for clip buffer and
      session media

Why SPI NAND in 8-pin SOIC and not eMMC: ARCHITECTURE.md explicitly
calls out "no BGA" for the storage to keep assembly simple at small
batch sizes. eMMC and BGA NAND require X-ray inspection and a stencil
+ reflow process that JLCPCB's economy assembly tier does not cover.

Connectors / footprints:
    - QSPI flash: SOIC-8 (W25Q16JV-IM or equivalent)
    - SPI NAND: SOIC-8 (Winbond W25N02 or Macronix MX35LF) -- pinout
      varies by vendor, lock to one part number once chosen
    - microSD: push-push SMT slot, hinged or fold-out

Layout:
    - QSPI traces are length-matched within ~5 mm; signals run no
      longer than necessary to keep at high-frequency boot
    - microSD detect line pulled up to 3.3 V; routed to SiP GPIO
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="ComputeStorage")
def compute_storage() -> None:
    """QSPI boot flash + SPI NAND + microSD slot."""
