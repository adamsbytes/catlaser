import Foundation

/// Pure decision logic for QR-payload acceptance.
///
/// Separated from the camera-driven scanner so the parse rules can
/// be exercised on Linux CI without AVFoundation. The scanner's
/// `metadataOutput(_:didOutput:from:connection:)` callback passes
/// captured payloads through this function; the first `Accepted`
/// return stops the capture session.
///
/// Three outcomes, each meaningful to the UI:
///
/// * `.accepted(PairingCode)` — a valid pair URL was recognised.
///   Stop scanning and hand the code to `PairingViewModel`.
/// * `.ignored` — the payload is a QR but not one we care about
///   (wrong scheme, non-URL text). Keep scanning silently.
/// * `.rejected(PairingCodeError)` — the payload LOOKS like ours
///   (catlaser scheme) but fails validation. Surfacing this lets
///   the UI show "this QR is for a Catlaser but looks corrupted —
///   try again or re-generate on the device". Keep scanning,
///   because a real QR is probably still in frame.
public enum QRPayloadDecision: Sendable, Equatable {
    case accepted(PairingCode)
    case ignored
    case rejected(PairingCodeError)

    /// Evaluate a raw payload string coming from the scanner. Pure;
    /// safe to call off the main thread.
    public static func evaluate(_ payload: String) -> QRPayloadDecision {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        // Only interpret our custom scheme; everything else (WiFi QR,
        // URL QR, vCard) silently bypasses. Case-insensitive on the
        // scheme to match `PairingCode.parse`.
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("\(PairingCode.scheme):") else {
            return .ignored
        }
        do {
            let code = try PairingCode.parse(trimmed)
            return .accepted(code)
        } catch {
            return .rejected(error)
        }
    }
}
