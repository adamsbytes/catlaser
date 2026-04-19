[X] Contracts (catlaser-common, proto/, SQLite)
  - [X] ServoCommand packed struct + constants (safety limits, pin maps)
  - [X] detection.proto (Rust↔Python IPC messages)
  - [X] app.proto (App↔Device API)
  - [X] buf.yaml + codegen pipeline (Rust + Python)
  - [X] SQLite schema (sessions, cat profiles, embeddings, schedule, chute state)

[X] MCU Firmware (catlaser-mcu)
  - [X] Embassy setup, task spawning, UART receive + command parsing
  - [X] 200Hz servo interpolation loop + PWM output
  - [X] Laser GPIO control
  - [X] Watchdog (500ms timeout → laser off, servos home, dispenser door closed)
  - [X] Beam-dwell monitor (Secure-world PWM compare readback, Class 2 dose cap)
  - [X] Power monitoring (VBUS ADC, supercap shutdown sequence)
  - [X] Dispenser servo control (disc/door/deflector, jam detection via stall timeout)
  - [X] Hopper sensor GPIO read + status LED

[X] Vision Pipeline (catlaser-vision, partial)
  - [X] V4L2/libcamera DMA capture from SC3336
  - [X] RKNN NPU inference wrapper (YOLO INT8, 640x480)
  - [X] Detection post-processing (NMS, bbox extraction)
  - [X] SORT tracker (Kalman filter + Hungarian matching)
  - [X] Track lifecycle (tentative → confirmed → coasting → dead)
  - [X] Person detection → safety ceiling computation

[X] Targeting + Serial (catlaser-vision → catlaser-mcu)
  - [X] Bbox center → servo angle transform (camera FOV, laser offset)
  - [X] Safety ceiling enforcement (clamp tilt above person threshold)
  - [X] ServoCommand packing + UART TX
  - [X] End-to-end: camera sees cat → laser tracks cat

[X] IPC + Cat Identity
  - [X] Unix socket server (Rust) + client (Python)
  - [X] Wire format: [1B type][4B length LE][protobuf]
  - [X] DetectionFrame streaming (Rust → Python, ~15/sec)
  - [X] TrackEvent + SessionRequest (Rust → Python, sporadic)
  - [X] BehaviorCommand + SessionAck + IdentityResult (Python → Rust)
  - [X] Cat re-ID: MobileNetV2 embedding on NPU (Rust side)
  - [X] Embedding comparison + catalog matching (Python side)

[X] Behavior Engine (catlaser_brain)
  - [X] State machine (lure / chase / tease / cooldown / dispense)
  - [X] Engagement tracking (cat velocity, pounce count, time-on-target)
  - [X] Per-cat profile adaptation (speed, smoothing, pattern randomness)
  - [X] Pattern generation (offset streaming per-frame to Rust)
  - [X] Cooldown → lead-to-point (left/right chute exit)
  - [X] Dispense orchestration (variable reward: tier 0-2, chute alternation)
  - [X] Session scheduling (read schedule, accept/skip logic)

[X] Storage + Networking
  - [X] SQLite CRUD (cat profiles, sessions, play history, embeddings, schedule)
  - [X] App API (protobuf over WebRTC data channel / TCP over Tailscale)
  - [X] WebRTC live view (LiveKit, H.264/265 from hardware encoder)
  - [X] Push notifications (FCM/APNs: play summaries, session alerts, hopper empty)

[X] Deploy + CI
  - [X] Cross-compile toolchain (ARM Cortex-A7 for vision, thumbv8m for MCU)
  - [X] ONNX → RKNN model conversion pipeline
  - [X] Rootfs overlay + init scripts (catlaser-vision, catlaser-brain)
  - [X] build-image.sh (full firmware image assembly)
  - [X] flash.sh (USB flash to device)
  - [X] catlaser-update.sh (OTA updates)
  - [X] CI: lint + test (Rust + Python) + release image builds

[ ] Coordination Server (better-auth)
  - [X] better-auth base (Postgres schema, bearer plugin, trusted origins pinned to Universal Link host)
  - [X] Social providers (Apple + Google, nonce three-way match: body + ID token claim + attestation bnd)
  - [X] Magic-link plugin (callbackURL allowlisted to Universal Link host — reject client-supplied hosts to block phishing-relay takeover)
  - [X] Universal Link handler (inert HTML at universalLinkPath, distinct from /api/auth/magic-link/verify; AASA serving iOS bundle ID)
  - [X] Device attestation plugin — v3 (SPKI parse, ECDSA verify over fph || bnd, per-tag binding parse)
  - [X] Binding enforcement (req: ±60s skew, ver: stored fph + pk byte-equal, sis: nonce three-way, out: ±60s skew, api: ±60s skew)
  - [X] Protected-route attestation middleware (api: binding on every authenticated call, per-session SE pubkey stored at sign-in, signature verify gates the request)
  - [X] Idempotency keys on mutating routes (server dedupes within skew window to block write-replay on captured attestations)
  - [X] Rate limiting (per-email + per-IP cooldown, enumeration-resistant identical 200 responses)
  - [X] Device pairing endpoint/flow
  - [ ] Cloudflare Tunnel deployment (cloudflared on VM, no inbound ports) + client pins 3–4 public roots CF chains through

[X] App — iOS (SwiftUI, primary)
  - [X] Proto codegen (swift-protobuf from app.proto)
  - [X] Sign in with Apple + Google (AuthenticationServices + GoogleSignIn SDK, ID token exchanged for better-auth bearer)
  - [X] Sign in with email magic link (Universal Links target, SE-signed attestation bound to each request and verify call)
  - [X] Sign in screen
  - [X] Signed HTTP client wrapper (SE-signs every authenticated request with api: binding, attaches x-device-attestation alongside bearer)
  - [X] Live view (LiveKit iOS SDK, WebRTC)
  - [X] Device pairing + endpoint persistence (QR pair flow, coordination-server-brokered Tailscale endpoint lookup, Keychain-persisted endpoint, auto-reconnect on network change, connection heartbeat, signed-out → endpoint wipe)
  - [X] History + cat profiles (stats, naming, management)
  - [X] Schedule setup (auto-play times, quiet hours)
  - [X] Push notifications (APNs: play summaries, session alerts, hopper empty)
  - [X] Xcode app target (com.example.catlaser, @main entry, root navigation, scenePhase lifecycle, LiveKit client-sdk-swift linked)

[ ] App — Android (Jetpack Compose, port)
  - [ ] Proto codegen (protobuf-kotlin from app.proto)
  - [ ] Sign in with Google (Credential Manager, ID token exchanged for better-auth bearer)
  - [ ] Sign in with email magic link (App Links target, Keystore-signed attestation bound to each request and verify call)
  - [ ] Signed HTTP client wrapper (Keystore-signs every authenticated request with api: binding, attaches x-device-attestation alongside bearer)
  - [ ] Port all screens from iOS (same flows, Compose equivalents)
  - [ ] Push notifications (FCM)

## iOS — values to swap before shipping

The Xcode target at `app/ios/App/CatLaserApp.xcodeproj` builds and launches out-of-the-box against placeholder values in `app/ios/App/CatLaserApp/Config.xcconfig`. Every placeholder is syntactically valid, so Xcode's build succeeds on a fresh checkout; a running app built against them will fail TLS pin verification on the first network call — which is the desired fail-closed posture, not a bug.

Before any build handed to a real user (TestFlight, App Store, side-loaded beta), swap each of the following in `Config.xcconfig`:

- `CATLASER_AUTH_BASE_URL` — production coordination-server URL (must be `https://`). Placeholder: `https://placeholder.invalid`.
- `CATLASER_AUTH_APPLE_SERVICE_ID` — Apple Sign In service identifier registered in App Store Connect against this bundle ID.
- `CATLASER_AUTH_GOOGLE_CLIENT_ID` — OIDC client ID from Google Cloud Console (iOS client type).
- `CATLASER_AUTH_UNIVERSAL_LINK_HOST` — host the magic-link email points at. Must serve an `apple-app-site-association` file that associates this bundle ID with the path below, and must differ from the API verify path.
- `CATLASER_AUTH_UNIVERSAL_LINK_PATH` — path on the universal-link host.
- `CATLASER_AUTH_OAUTH_REDIRECT_HOSTS` — comma-separated hosts trusted to receive the Google OIDC redirect.
- `CATLASER_LIVEKIT_HOSTS` — comma-separated hostnames of the operator-run LiveKit deployment. A `StreamOffer` whose URL host is not in this set is refused before the LiveKit SDK ever sees it.
- `CATLASER_OBSERVABILITY_DEVICE_ID_SALT` — fresh 32-byte random string. Rotating it is a backwards-incompatible change (existing installs read as new devices afterwards).
- `CATLASER_TLS_SPKI_SHA256_PINS` — comma-separated, base64-encoded SHA-256 digests of the `SubjectPublicKeyInfo` of each pinned certificate. Compute with: `openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`. Pin intermediate CA(s) with one or more offline backup pins per RFC 7469.
- `CATLASER_PRIVACY_POLICY_URL` — absolute `https://` URL of the privacy policy linked from Settings → About. App Store Review 5.1.1 rejects submissions whose in-app privacy link 404s; validate before every archive.
- `CATLASER_TERMS_OF_SERVICE_URL` — absolute `https://` URL of the terms of service linked from Settings → About.

Entitlements also need attention on the first real build:

- `CatLaserApp.entitlements` has `aps-environment = development`. Override to `production` in the Release configuration before archiving for TestFlight or the App Store (a mismatched entitlement causes APNs to silently refuse to hand out tokens).
- `CODE_SIGN_STYLE = Automatic` with no `DEVELOPMENT_TEAM` set — add the team ID to a local `~/.xcconfig` include or via Xcode's Signing & Capabilities pane. Do not commit a team ID.

App-icon artwork is a placeholder empty `AppIcon.appiconset`. Drop a 1024×1024 PNG into that directory before archiving — Apple rejects submissions without an app icon.

