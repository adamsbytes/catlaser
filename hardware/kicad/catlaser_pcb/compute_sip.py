"""RV1106G3 SiP: Cortex-A7 + 1 TOPS NPU + 256 MB DDR3L + Wi-Fi 6.

The SiP packages the SoC, DDR3L, and Wi-Fi MAC/PHY in one BGA. There
are NO external DDR traces -- one of the main reasons for choosing
this part. The remaining external interfaces are the ones we route on
this PCB:

    - Power rails: VDD_CORE, VDD_LOGIC, VDD_IO_3V3, VDD_PMU,
      VDD_DDR_1V35 (internal to SiP but pin-exposed for decoupling)
    - Power sequencing: per Rockchip reference design, must come up in
      the documented order to avoid latch-up
    - QSPI (boot): -> compute_storage.py (W25Q16-class boot flash)
    - SPI NAND: -> compute_storage.py (256 MB SPI NAND)
    - SDIO/microSD: -> compute_storage.py
    - MIPI-CSI-2: -> camera_mipi.py (SC3336)
    - RF: antenna pin -> wifi_rf.py (chip antenna or U.FL)
    - UART2 (or UART4): <-> RP2350 UART0 (115200 baud, ServoCommand
      + SHUTDOWN_SIGNAL byte)
    - GPIO: hopper sensor read (HOPPER_SENSE from hopper_sensor.py)
    - Debug UART: header for console (optional, dev-only)

Power sequencing controller (PMIC or discrete LDOs + supervisor)
TBD on Rockchip reference. Likely RK809 or discrete since RK809 may
be overkill for this load profile.

LAYOUT REQUIREMENTS (carry into kicad_pcb):
    - 4-layer minimum stackup
    - Controlled impedance on MIPI-CSI differential pairs (100 ohm
      diff) and the RF trace to antenna (50 ohm single-ended)
    - Solid GND pour under SiP, no splits
    - Decoupling: 1x 10 uF + 4x 1 uF + 8x 100 nF distributed under
      BGA per Rockchip reference; placed on opposite layer with vias
      under the pads
    - Antenna keep-out zone per chip-antenna datasheet

This is by far the most layout-sensitive subsystem. Plan to iterate on
the .kicad_pcb manually after the netlist is generated; circuit-synth
preserves placement on regen.
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="ComputeSiP")
def compute_sip() -> None:
    """RV1106G3 BGA, decoupling, power sequencing."""
