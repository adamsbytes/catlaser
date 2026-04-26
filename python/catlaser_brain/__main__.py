"""Entry point for ``python -m catlaser_brain``.

Reads daemon configuration from environment variables, constructs the
orchestrator, and runs the main loop. The init system supervises this
process; on any unhandled exception or main-loop exit, the supervisor
restarts the daemon.

Exit codes:

* ``0`` -- clean shutdown (SIGTERM / SIGINT received).
* ``1`` -- configuration error before the loop began (bad env vars,
  unreachable tailnet interface, unreadable device key, etc.). The
  init system should NOT auto-restart on this — it indicates a
  deployment problem the supervisor cannot fix on its own.
* ``2`` -- fatal runtime error inside the loop. The supervisor restarts.
"""

from __future__ import annotations

import logging
import sys

from catlaser_brain.daemon.config import ConfigError, DaemonConfig
from catlaser_brain.daemon.orchestrator import Daemon

EXIT_OK = 0
EXIT_CONFIG_ERROR = 1
EXIT_RUNTIME_ERROR = 2


def main() -> int:
    """Daemon entry point.

    Returns the process exit code. Exposed as a function so tests can
    drive the same path the ``__main__`` block executes without
    reimporting the module under a fresh interpreter.
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )
    logger = logging.getLogger("catlaser_brain")

    try:
        config = DaemonConfig.from_env()
    except ConfigError:
        logger.exception("daemon configuration failed; not retrying")
        return EXIT_CONFIG_ERROR

    daemon = Daemon(config)
    try:
        daemon.run()
    except Exception:
        logger.exception("daemon main loop crashed")
        return EXIT_RUNTIME_ERROR

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
