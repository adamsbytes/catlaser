"""Catlaser AIO PCB — circuit-synth source of truth.

Each module defines one subsystem as a ``@circuit`` function. ``top.py``
assembles them and emits the KiCad project under ``project/``.
"""

from __future__ import annotations
