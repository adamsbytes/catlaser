r"""AuthResponse signing — device's proof of identity to the app.

The app's handshake (see :mod:`~catlaser_brain.auth.handshake`) proves
that the *client* holds a Secure-Enclave key whose SPKI is on the ACL.
This module is the symmetric step: the device proves to the app that
*it* is the legitimate device, not an impostor TCP listener sitting
where the Tailscale endpoint should be.

The proof is an Ed25519 signature over a canonical transcript:

    b"catlaser-auth-response-v1\x00"   # 26-byte domain separator
    || nonce                           # 16 bytes (echoed from request)
    || signed_at_unix_ns.to_bytes(8, "little", signed=True)
    || b"\x01" if ok else b"\x00"
    || reason.encode("utf-8")

The signing key is the device's Ed25519 private key from
:class:`~catlaser_brain.auth.identity.DeviceIdentity` — the same key
whose public half the coordination server republishes to the app in
the pairing response. The app verifies with that public key.

Replay resistance:

* ``nonce`` binds the response to a specific request. A signature
  captured once cannot be presented against a future handshake whose
  app-generated nonce is different.
* ``signed_at_unix_ns`` covers the rare case where an attacker replays
  a captured response to a victim whose nonce happens to collide (1
  in 2**128 per handshake) — the app enforces a ±5-minute skew window
  so a stale signature is refused even if the nonce matched.
* The domain separator defends against cross-protocol signature reuse:
  a future message format signing with the same key cannot be coerced
  into a byte sequence that validates as an AuthResponse transcript
  and vice versa.

Nonce validation (request-side):

The device also validates that the request's ``nonce`` is exactly 16
bytes before it even attempts signature verification. A shorter or
longer value, or an empty one, aborts the handshake with
:attr:`~catlaser_brain.auth.handshake.HandshakeReason.NONCE_INVALID`
so an attacker who omitted the field (or sent `""`) cannot coerce the
device into signing an empty-nonce transcript.
"""

from __future__ import annotations

from typing import Final

AUTH_RESPONSE_DOMAIN: Final[bytes] = b"catlaser-auth-response-v1\x00"
"""Domain-separator prefix for the AuthResponse transcript.

Must match the iOS :class:`HandshakeResponseVerifier` constant. A
change on either side is a breaking protocol-version bump; the
``-v1`` suffix exists so a future revision can introduce a distinct
prefix without breaking old peers mid-upgrade.
"""

NONCE_LENGTH: Final[int] = 16
"""Required length of ``AuthRequest.nonce`` / ``AuthResponse.nonce``.

16 bytes = 128 bits of entropy. Nonce collisions across two
legitimate handshakes at that width are ~2**-64 per pair, far below
the threshold where any replay worry matters. Smaller values would
not be safe; larger values are wasteful and the app sizes its
``SecRandomCopyBytes`` call to match this constant.
"""


def build_auth_response_transcript(
    *,
    nonce: bytes,
    signed_at_unix_ns: int,
    ok: bool,
    reason: str,
) -> bytes:
    """Return the canonical bytes the device signs for an AuthResponse.

    Args:
        nonce: Exactly :data:`NONCE_LENGTH` bytes, echoed from the
            request. Caller must have validated the length already;
            this helper does not re-check so both success and failure
            paths produce byte-identical transcripts for the same
            inputs.
        signed_at_unix_ns: Device's wall-clock reading at signing
            time, nanoseconds since Unix epoch. Encoded as a signed
            8-byte little-endian integer because ``int64`` is the
            proto wire type.
        ok: ``True`` for accept, ``False`` for reject. Single byte so
            an attacker cannot coerce a ``False`` signature to be
            accepted as ``True`` through transcript manipulation.
        reason: UTF-8 string from
            :class:`~catlaser_brain.auth.handshake.HandshakeReason`
            (or empty when ``ok`` is ``True``).

    Returns:
        The bytes to be passed to ``Ed25519PrivateKey.sign``.
    """
    ok_byte = b"\x01" if ok else b"\x00"
    signed_at_bytes = signed_at_unix_ns.to_bytes(8, "little", signed=True)
    reason_bytes = reason.encode("utf-8")
    return AUTH_RESPONSE_DOMAIN + nonce + signed_at_bytes + ok_byte + reason_bytes
