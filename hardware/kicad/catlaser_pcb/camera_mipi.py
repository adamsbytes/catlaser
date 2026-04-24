"""SC3336 camera: MIPI-CSI-2 ribbon connector + sensor power.

The SC3336 module mounts in the enclosure on a flex cable. This board
exposes a 24-pin (typical) FPC connector for the ribbon -- the sensor
itself is not on this PCB.

Lines on the ribbon:
    - MIPI-CSI-2 differential pairs: CLK_P/N, D0_P/N (1-lane is
      sufficient for 640x480 @ 15 fps after ISP)
    - I2C (SCCB) for sensor configuration: SDA, SCL
    - Reset, power-down (pulled to defaults by SiP GPIOs)
    - Power: VDD_2V8 (analog), VDD_1V8 (digital + IO), VDD_1V2 (core)
    - GND

Layout requirements:
    - MIPI-CSI pairs: 100 ohm differential impedance, length-matched
      within tolerance per Rockchip MIPI-CSI guide
    - Connector placed at the edge nearest the camera mount in the
      enclosure to minimise ribbon length
    - Camera-side voltages derived locally (small LDOs) since the
      SiP rails may not include all three

The SC3336 ISP tuning files are pre-calibrated for this sensor (per
BRIEF.md); no on-board trimpots or calibration headers needed.
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="CameraMIPI")
def camera_mipi() -> None:
    """SC3336 MIPI-CSI ribbon connector + per-rail LDOs."""
