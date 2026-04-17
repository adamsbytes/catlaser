# ADR-006: Cloudflare-Fronted Coordination Server with Per-Request Device Attestation

## Status

Accepted

## Context

The coordination server runs better-auth and brokers every authenticated interaction between the apps and the device fleet — sign-in, session management, schedule sync, LiveKit token minting, push registration, device-pairing QR validation. It is the only server in the system and the only TLS-exposed origin owned by the project. Three independent pressures bear on how it ships and how clients talk to it.

**Operational exposure.** A VM with inbound 443 open to the internet is a perpetual patching commitment — kernel CVEs, web-server CVEs, sshd hardening, DDoS absorption, fail2ban, certbot renewal cron jobs, firewall drift. For a single-operator product this is background work that grows with fleet size and never pays down.

**TLS pinning and longevity.** The iOS client ships with SPKI pinning (see `PinnedSessionDelegate` in `CatLaserAuth`) because system trust alone does not stop a MitM with a rogue cert from a trusted CA (corporate proxies with installed roots, compelled CA issuance, compromised intermediates). Pinning a leaf or intermediate that the project controls end-to-end requires coordinating every cert rotation with an app release — a cadence the project cannot sustain at small scale without risking broken clients on an unexpected expiry.

**Bearer-token risk after sign-in.** The v3 attestation system binds sign-in ceremonies (`requestMagicLink`, `completeMagicLink`, `exchangeSocial`, `signOut`) to the Secure Enclave key on the device. Once sign-in completes, subsequent app-to-server calls carry only the bearer token. An attacker who captures a bearer in transit — via any TLS bypass, a corporate MitM the user didn't notice, or a briefly-compromised network path — can impersonate the user until the bearer expires. The sign-in hardening does not extend to protected routes, and this is the single largest residual risk against a product that streams live video of someone's home.

The three resolve together. Fronting the server with Cloudflare Tunnel removes the inbound-port exposure, hands TLS termination to Cloudflare's edge, and obsoletes the own-intermediate pinning problem — but it also extends the trust boundary to include Cloudflare and eliminates end-to-end TLS to the project's own cert. Accepting that looser trust model is only safe if the bearer-alone risk is closed, because a Cloudflare-terminated path is by definition one where plaintext exists at a location the project does not control. Extending attestation from sign-in to every authenticated request closes exactly that gap: a captured bearer is useless without a fresh SE signature an attacker cannot produce.

## Decision

Deploy the coordination server behind Cloudflare Tunnel, pin public roots on the client, and extend device attestation to every authenticated API call.

**Cloudflare Tunnel deployment.** The VM hosting the server runs `cloudflared` as a systemd service, establishing an outbound-only persistent connection to Cloudflare's edge. The VM has no inbound ports open — not 443, not 22. Management access (ssh, psql) moves to Tailscale, which is a separate trust boundary from the client-facing TLS posture. Clients connect to `api.<domain>` at Cloudflare's edge; CF proxies to `localhost:<port>` on the VM over the tunnel.

**Client TLS pinning targets public roots, not intermediates.** `TLSPinning` is configured with 3–4 public root CAs currently present in Cloudflare's edge certificate chain. Roots rotate on ~10–20 year timescales and are refreshed in the app on a ~5 year cadence with backups for robustness. The client still runs full system trust evaluation (CA validity, hostname, OCSP, CT) — pinning only tightens acceptance, never loosens it. This posture accepts that any cert chained to a CF-approved root validates, which is the structural cost of CF-edge termination.

**Per-request attestation via `.api(timestamp:)`.** A fifth `AttestationBinding` case renders as `bnd = "api:<unix_seconds>"`, same format and skew contract as `.request` and `.signOut`. Every authenticated HTTP call from the iOS app flows through a `SignedHTTPClient` wrapper that asks `DeviceAttestationProviding` for a fresh attestation, attaches `x-device-attestation: <base64 payload>` alongside `Authorization: Bearer <token>`, and sends. Server middleware on every protected route:

1. Parses the attestation header; asserts `v = 3` and the `api:` binding tag.
2. Looks up the session by bearer; pulls the SE public key stored on the session row at sign-in time from `attestation.pk`.
3. Verifies the ECDSA signature over `fph_raw || bnd_utf8` using the stored pubkey.
4. Enforces the ±60s skew window on the timestamp.
5. Rejects with 401 on any failure.

**Mutating routes additionally require a client idempotency key.** Clients generate a UUID per mutating request and attach it as `Idempotency-Key: <uuid>`. The server records successful responses keyed by `(session_id, idempotency_key)` for at least the skew window; replays within that window return the cached response without re-executing the mutation. This closes the residual risk where a captured `(bearer, attestation)` pair would otherwise be replayable against a mutating endpoint within the 60s skew.

## Consequences

- The coordination server has no inbound ports. Cert issuance, renewal, and DDoS absorption become Cloudflare's responsibility. Management-plane access moves entirely to Tailscale.
- Cloudflare holds session keys at the edge and sees plaintext for every authenticated request, including bearer tokens and request bodies. This is an accepted trust extension, mitigated by per-request attestation making the bearer alone insufficient to act.
- Client pinning becomes rotation-tolerant. The project no longer maintains an intermediate cert or a rotation runbook tied to app releases. Roots refresh on multi-year timescales; multiple pins ship together so any single root rotation is non-disruptive.
- Per-request SE signing adds ~5–15ms of latency to every authenticated call. Acceptable for UI operations; imperceptible at normal request rates. Battery impact is negligible at realistic traffic volumes.
- A bearer leaked via any mechanism — TLS bypass, corporate MitM, log scrape — cannot be used to impersonate the user without also producing a fresh SE signature. The SE key is non-extractable; an attacker holding only the bearer has no useful primitive.
- Captured `(bearer, attestation)` pairs have a bounded 60s replay window. Read replay within that window tells the attacker nothing they didn't already see; write replay is blocked by server-side idempotency dedup.
- Server middleware changes shape: every authenticated route now requires both a bearer check and an attestation verify. `api:` binding parsing, pubkey lookup, and P-256 signature verification become hot-path operations; at P-256 verify speeds (microseconds) this is not a bottleneck.
- The iOS client gains a `SignedHTTPClient` wrapper that centralizes attestation signing. Call sites that previously constructed `URLRequest` directly now route through this wrapper; forgetting to do so produces 401s immediately, making the invariant self-enforcing.
- Android port inherits the same design with Android Keystore in place of Secure Enclave.
- Local dev against the server without cloudflared requires a pinning bypass in debug builds (`#if DEBUG` gate). The bypass is package-internal, same access-control pattern as `KeychainBearerTokenStore.AccessPolicy.accessibilityOnly`, so it cannot reach release binaries.
