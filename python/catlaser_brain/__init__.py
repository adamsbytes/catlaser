"""Catlaser Python behavior sidecar.

The daemon orchestrates the play loop on the compute module: it consumes
detection frames from the Rust vision daemon over IPC, drives the
behavior state machine, ships behavior commands back, and serves the
mobile app over TCP on the tailnet interface.

The package itself is import-only — the runnable entry point is
``python -m catlaser_brain``, which delegates to
:mod:`catlaser_brain.daemon.orchestrator`.
"""

from __future__ import annotations
