"""Servo headers: 5x JST-XH 2.54 mm, 3-pin (signal / VCC_5V / GND).

Connectors:
    J_PAN       -> MG90S, GPIO2
    J_TILT      -> MG90S, GPIO3
    J_DISC      -> SG90,  GPIO4
    J_DOOR      -> SG90,  GPIO5
    J_DEFLECTOR -> SG90,  GPIO6

All servos run from the supercap-backed VCC_5V rail. Worst-case stall
current per MG90S is ~700 mA; the rail and supercap charger must size
for 5 servos x ~300 mA continuous worst case (~1.5 A) plus transient
stall headroom.

PWM signal protection: 100 R series resistor + small TVS on each
signal line at the connector. Servos are user-replaceable per
ARCHITECTURE.md; ESD strikes via the connector are the dominant fault
mode and must not propagate to the RP2350 GPIOs.

Layout: cluster the 5 connectors along one board edge so the user can
seat them blind during assembly.
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="ServoHeaders")
def servo_headers() -> None:
    """Five JST-XH 3-pin connectors with series protection on PWM lines."""
