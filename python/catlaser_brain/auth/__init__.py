"""Device-side authentication: Ed25519 identity, coordination-server client, ACL.

Three concerns:

* :mod:`~catlaser_brain.auth.identity` — device Ed25519 keypair. Generated
  once on first boot, stored at ``/var/lib/catlaser/device.key`` (0600),
  re-used on every subsequent call to the coordination server.
* :mod:`~catlaser_brain.auth.coord_client` — HTTPS client that attaches the
  three ``x-device-*`` headers required by the server's device-attestation
  middleware. Handles the one-shot ``/provision`` call plus the recurring
  ``/pairing-code`` and ``/acl`` calls.
* :mod:`~catlaser_brain.auth.acl` — ACL cache + polling task. Owns the
  in-memory set of authorized user SPKIs; the app server reads this set on
  every inbound TCP handshake to decide whether to accept or disconnect.
* :mod:`~catlaser_brain.auth.handshake` — parses an app-supplied v4
  ``x-device-attestation`` header with a ``dev:<ts>`` binding, verifies the
  ECDSA signature, and matches the signer's SPKI against the ACL.
"""

from __future__ import annotations
