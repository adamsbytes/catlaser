# Automated Cat Laser — Project Brief

## Architecture
Split-brain design. A Luckfox Pico Ultra W (Rockchip RV1106G3, Cortex-A7 + 1 TOPS NPU, hardware H.265 encoder, onboard WiFi 6, ~$12) runs Linux and handles all vision, behavior, networking, and video. An RP2040 (~$0.80) runs bare-metal Rust at 200Hz handling servo interpolation, PWM output, laser GPIO, mechanical tilt limits, and a 500ms watchdog that kills the laser if the compute module goes unresponsive. Communication between them is an 8-byte packed UART struct containing target pan/tilt angles, laser state, and smoothing parameters. The MCU is the safety layer — it enforces a hard mechanical horizon limit regardless of what the compute module requests.

## Vision Pipeline
SC3336 3MP camera (known compatible, ISP tuning pre-calibrated, good low-light) feeds 640x480 to the ISP. YOLOv5/v8-nano quantized INT8 runs on the NPU at ~15 FPS, detecting cats and people in a single pass. Person detections compute a dynamic safety ceiling at 75% of the lowest detected person's bounding box height — the laser stays below that line, allowing floor-level play to continue with humans in frame. Stock COCO weights work for v1 detection; fine-tune later from real deployment data if needed.

## Tracking (SORT)
Each detected cat bbox is matched to persistent track objects via IOU + Hungarian algorithm. Tracks maintain a Kalman filter over [x, y, w, h, dx, dy, dw, dh] — position plus velocity. Matching costs microseconds on CPU. Tracks go tentative → confirmed (3+ hits) → coasting (no match) → dead (30 frames unmatched). Identity is assigned once at confirmation, not per-frame.

## Cat Re-ID
On track confirmation, crop the cat bbox, run a MobileNetV2 embedding model (128x128 input, 128-dim output) on the NPU (~15ms, runs only a few times per session). Average embeddings over 5 frames, cosine-similarity match against stored cat profiles. >0.75 similarity = known cat, below = prompt user to name a new cat. Re-verify identity when a track resumes after coasting to prevent swaps during occlusion. Log all crops and embeddings on-device (with consent) for future model improvement. Two similar-looking cats will sometimes confuse the system — be honest about this limitation.

## Behavior Engine
Python state machine on the compute module. Modes: lure (slow movement to attract attention), chase (lead the cat, adjust speed to maintain engagement), tease (pause, juke, erratic movement), cooldown (slow to a stop, lead toward a treat location to end sessions positively). The engine tracks engagement heuristics — cat velocity, pounce frequency, time-on-target — and adapts per cat profile over sessions. Tuning parameters (smoothing factor, slew rate, pattern randomness) are what get adjusted, not neural network weights. The "learning" is parameter adaptation in a state machine, not on-device ML training.

## Servo/Laser Hardware
Two MG90S metal gear servos (~$3-4/pair) in a rigid pan/tilt mount. 5mW 650nm Class 3R laser diode (~$1) driven via GPIO through a transistor. The MCU interpolates smoothly between the 15 FPS target updates from the compute module, producing butter-smooth motion at 200Hz. Max slew rate limits prevent servo buzz. The entire control firmware is ~500-800 lines of Rust using Embassy async runtime.

## Power & Safety
USB-C input, 5V. A 10F supercap (~$1) provides 5-8 seconds of hold-up time on power loss. The MCU monitors VBUS voltage at 10Hz; on drop, it kills the laser within 100ms, parks servos, signals the Pi for filesystem-safe shutdown, then sleeps. The compute module runs a read-only root filesystem with a journaled writable data partition. Laser safety: mechanical tilt stop (hardware, non-bypassable), dynamic person-height ceiling (software, on compute module), watchdog timeout (firmware, on MCU). Belt and suspenders — any single layer failing still keeps the product safe.

## Networking & App
Tailscale/WireGuard on-device. Device registers to your coordination server on first setup, app pairs via QR code. Local network access is free tier — full functionality over WiFi without any subscription. Premium ($3-5/mo or ~$35/yr) adds remote relay for NAT-unfriendly networks. Live view via WebRTC (use LiveKit) over the tunnel, H.264/265 from the hardware encoder. Push notifications via APNs (iOS) / FCM (Android) for play summaries and live session alerts. Native apps: SwiftUI (iOS, primary) + Jetpack Compose (Android) — thin clients against the proto contract. Four core screens: sign in, live view, history/cat profiles, schedule setup. Firebase Auth for sign-in with Apple/Google.

## Compliance
FCC: pre-certified WiFi module on the Luckfox means you only need SDoC (self-declaration) testing for unintentional emissions from your PCB — ~$1500-2500 at a test lab. No FCC application or review. FDA/CDRH: laser products require a product report filed under 21 CFR 1040.10, proper classification labels, safety interlocks, and an accession number before shipping. Use Laser Notice 56 (IEC 60825-1:2014). Budget $1-3K, hire a laser safety consultant for at least an initial review. Product liability insurance ~$1-2K/year. Total regulatory budget: ~$5-8K.

## BOM & Pricing
Per unit at 100-unit scale: compute module $12, MCU $0.80, camera $5, servos $3.50, laser $1, PCB assembled $3.50, supercap + power $2.50, storage $9 (256MB SPI NAND + 2GB microSD + 2MB QSPI flash), enclosure $8-12 (3D printed or farmed at small scale, injection mold at 500+), misc $2. Total BOM ~$44-49. Retail at $99. Gross margin ~$36-41/unit before fulfillment, payment processing, shipping (~$13-15 combined), and warranty reserve (5-10%). Net margin ~$16-21/unit.

## Manufacturing Path
Prototype: dev boards + breadboard + 3D print, ~$100-150 total, validate all software. Engineering prototype: custom PCB via KiCad, order 5-10 assembled from JLCPCB, 2-3 revisions, ~$300-400. Small production (100 units): JLCPCB assembles PCBs, you order components in bulk, final assembly is manual — seat compute module, mount servos/camera/laser in enclosure, plug connectors, flash firmware, run test script. ~20 min/unit. Enclosures 3D printed in PETG/ASA or farmed to a print service. Sell direct via Shopify. Don't build 500 units before selling 50.

## Marketing
The product generates shareable cat content as a byproduct. Highlight clips of high-engagement play sessions auto-save to the app. Every shared clip is organic marketing. Seed 20-30 units to mid-tier cat-focused social accounts. Address the "laser frustration" criticism proactively — the behavior engine ends sessions by leading cats to a treat spot. Positioning: not a cheap toy, a genuine enrichment device for indoor cats with data to prove engagement.