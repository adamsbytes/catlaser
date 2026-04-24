"""Power: USB-C 5 V in, supercap-backed 5 V rail, 3.3 V LDO.

Inputs:
    - VBUS from USB-C receptacle (5 V nominal)

Outputs:
    - VCC_5V: supercap-backed servo + laser-driver rail
    - VCC_3V3: logic rail (RP2350, RV1106G3, NAND, microSD)
    - GND

Topology:
    USB-C (USB 2.0, CC1/CC2 5.1 kohm pull-downs)
        -> charger IC (MCP73871-class): inrush limit, charge regulation,
           auto power-path from VBUS to supercap on USB drop
        -> 10 F / 5.5 V supercap on the 5 V rail
        -> 3.3 V LDO/buck downstream

Why supercap on 5 V (not 3.3 V): the brownout sequence in
catlaser-mcu must complete a "park to home" servo move before sleeping;
that requires the 5 V servo rail to remain energised for ~5 s. Backing
3.3 V alone would freeze the servos wherever they were when power
dropped. See ADR-008.

Why constant-current charger IC (not bare MOSFET + sense R): a
discharged supercap is a near-short on plug-in; an unmanaged inrush
trips the host overcurrent protection and stresses the cable.

Pin-level constants (VBUS divider 200K/100K to ADC0/GPIO26,
SHUTDOWN_SIGNAL byte over UART) live in
catlaser-common/src/constants.rs and must match the firmware exactly.
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="Power")
def power() -> None:
    """USB-C input, supercap holdup, 3.3 V derivation."""
