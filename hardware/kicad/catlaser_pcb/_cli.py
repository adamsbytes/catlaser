"""Resolve KiCad CLI binaries to absolute paths once, fail loudly if missing.

Lazy resolution keeps imports cheap; only the call site that actually
shells out hits the ``shutil.which`` lookup, and only the first call
pays for it (``lru_cache``).
"""

from __future__ import annotations

import shutil
from functools import lru_cache


@lru_cache(maxsize=1)
def kicad_cli_path() -> str:
    """Return the absolute path to ``kicad-cli`` or raise.

    Raises:
        RuntimeError: if ``kicad-cli`` is not on PATH. KiCad 10+ system
            package provides it.

    """
    path = shutil.which("kicad-cli")
    if path is None:
        msg = "kicad-cli not found in PATH (install KiCad 10+ system package)"
        raise RuntimeError(msg)
    return path
