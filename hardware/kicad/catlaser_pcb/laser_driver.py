"""Laser driver: AMC7135 constant-current sink, GPIO-gated.

Class 2 visible CW laser diode (650 nm, <= 1 mW optical output) per
constants.rs LASER_MAX_POWER_UW = 1000.

Topology:
    VCC_5V -> laser diode anode
              laser diode cathode -> AMC7135 OUT
                                     AMC7135 GND -> GND
                                     AMC7135 VDD -> VCC_5V (or VCC_3V3
                                                    per datasheet)
                                     AMC7135 EN  <- LASER_EN (RP2350 GPIO7)

The AMC7135 sinks a fixed 350 mA when enabled; the BOM laser diode is
specified to land below the Class 2 1 mW optical ceiling at that drive.
Constant-current operation means optical output is independent of VBUS
sag during supercap holdup -- the FDA Class 2 dose-per-exposure
argument depends on this determinism.

LASER_EN is driven by RP2350 GPIO7, which is owned by the Secure world
(catlaser-mcu-secure) and physically inaccessible to Non-Secure
firmware via ACCESSCTRL. See ADR-005.

Notes for layout:
    - Laser diode and AMC7135 placed close to minimise loop inductance.
    - Series ESD protection (TVS to GND) on LASER_EN at the connector
      if the diode + driver are on a flying-lead module.
    - Bypass: 1 uF X7R within 5 mm of AMC7135 VDD.
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="LaserDriver")
def laser_driver() -> None:
    """AMC7135 constant-current sink, GPIO-gated by Secure-world LASER_EN."""
