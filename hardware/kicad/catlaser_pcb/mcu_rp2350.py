"""RP2350 MCU: servo control, UART to compute, TrustZone-M safety.

Includes:
    - RP2350 (QFN-60), decoupling, 12 MHz crystal
    - 2 MB QSPI boot flash (W25Q16JV-class)
    - SWD debug header (10-pin Cortex-M)
    - BOOTSEL button + RUN reset button
    - Status LED on GPIO25 (per constants.rs)

Pin assignments are FIXED by catlaser-common/src/constants.rs:372-407.
Any reassignment here is a firmware-breaking change and requires a
matching edit in constants.rs plus a regression sweep of the MCU tests.

    GPIO0  UART0 TX  -> compute module RX
    GPIO1  UART0 RX  <- compute module TX
    GPIO2  PWM (pan servo)
    GPIO3  PWM (tilt servo)
    GPIO4  PWM (disc servo)
    GPIO5  PWM (door servo)
    GPIO6  PWM (deflector servo)
    GPIO7  laser enable -> laser_driver.py (Secure-world owned)
    GPIO25 status LED
    GPIO26 VBUS sense (ADC0, behind 200K/100K divider in power.py)
    GPIO27 hopper IR sensor (digital in)

PWM slice mapping matters: the dwell monitor in catlaser-mcu-secure
reads PWM_CH1_CC directly. GPIO2/GPIO3 are slice 1 channels A/B
respectively, which is the dwell monitor's expected layout.

Power: 3.3 V -> IOVDD, DVDD (1.1 V via internal core LDO from VREG_IN),
ADC_AVDD with ferrite + 100 nF.
"""

from __future__ import annotations

from circuit_synth import circuit


@circuit(name="MCU_RP2350")
def mcu_rp2350() -> None:
    """RP2350 + boot flash + SWD + reset/bootsel."""
