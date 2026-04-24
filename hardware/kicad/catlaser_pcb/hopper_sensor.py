"""Hopper IR break-beam sensor: dual-reader connector.

Single GPIO line read by BOTH the RP2350 (GPIO27, status LED + jam
detection) and the RV1106G3 (Python session-gating). The MCU and
compute module are read-only -- there is no UART return channel for
hopper state, the GPIO IS the channel.

Connector: JST-PH 2 mm 4-pin
    1: VCC_3V3 (sensor power)
    2: GND
    3: SENSE  (open-collector or push-pull, polarity per BOM choice)
    4: shield/NC

Pull-up: 10 kohm to 3.3 V at the board side. Sensor pulls low when the
beam is broken (i.e. treats present); high = empty. Polarity is
asserted in catlaser-common/src/hopper.rs and must match.

Layout: SENSE net fans out to two GPIOs (RP2350 GPIO27, RV1106G3 input
TBD in compute_sip.py). Both inputs are high-impedance reads; no
buffer needed.
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="HopperSensor")
def hopper_sensor() -> None:
    """IR break-beam connector, pulled up to 3.3 V, fanned to MCU and SiP."""
