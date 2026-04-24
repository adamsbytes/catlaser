"""Wi-Fi RF: antenna + matching network for the RV1106G3 on-die radio.

The RV1106G3 SiP integrates the Wi-Fi 6 MAC/PHY/RF -- there is no
external radio module. This subsystem covers the antenna feed.

Choices to lock at fab time:
    - Chip antenna (Johanson 2450AT43A100 or similar): cheaper, no
      U.FL connector, but the keep-out and matching network are
      antenna-specific.
    - U.FL connector to an external whip: easier compliance testing,
      higher BOM cost, exposes a connector the user can break off.

Pi-network matching pads (3 components: series-shunt-series) regardless
of antenna choice, populated based on VNA sweep of the assembled board.
Default-populate per the antenna vendor's reference, then trim during
EVT.

Layout:
    - 50 ohm controlled-impedance trace from SiP RF pin to antenna
      feed point or U.FL connector
    - Antenna keep-out zone per vendor datasheet -- no copper, no
      vias, no traces under the antenna body
    - Solid GND pour ringing the antenna feed, no splits
    - This is the FCC SDoC-relevant subsystem; the layout determines
      whether the pre-certified Wi-Fi module exemption applies (for
      the RV1106G3 it does, but only if the antenna integration
      follows the SiP vendor's reference)
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="WiFiRF")
def wifi_rf() -> None:
    """Antenna + pi-network matching from SiP RF pin."""
