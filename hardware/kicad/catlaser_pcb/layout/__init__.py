"""Layout-as-code: footprint placement, tracks, zones, board outline.

Each subsystem has a peer module here that mirrors the schematic
module of the same name in the parent package. The schematic module
defines what components exist and how they connect; the layout module
defines where they sit and how their copper is drawn.

All layout modules take a connected ``kipy.board.Board`` and operate on
it in place, then the pipeline entry in ``catlaser_pcb.pcb`` saves the
result back to disk.
"""

from __future__ import annotations
