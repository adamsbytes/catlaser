import Foundation

/// User-facing copy for the pairing screen. Kept in one place so the
/// pairing view and its failure banners stay consistent, and so a
/// future localisation pass touches exactly one file.
public enum PairingStrings {
    public static let title = "Pair your Catlaser"
    public static let scanningPrompt = "Point your camera at the QR code on your Catlaser."
    public static let scanningHint = "Hold steady. We'll pair automatically."
    public static let manualEntryButton = "Enter code manually"
    public static let scanInsteadButton = "Scan with camera"
    public static let manualEntryPlaceholder = "catlaser://pair?code=..."
    public static let manualSubmitButton = "Pair"
    public static let exchangingLabel = "Connecting to your Catlaser…"
    /// Busy-state copy for ``PairingPhase.checkingExisting``. The VM
    /// is doing a keychain read plus a Secure-Enclave-signed ownership
    /// re-verification against the server; on a cold cellular launch
    /// that takes noticeable wall time. Labelling the spinner removes
    /// the "is anything happening?" ambiguity a bare ``ProgressView``
    /// would create on the paired-launch path.
    public static let checkingExistingLabel = "Looking for your Catlaser…"
    public static let pairedTitle = "Paired"
    public static let pairedSubtitle = "Your Catlaser is linked to this account."
    public static let unpairButton = "Unpair this Catlaser"
    public static let retryButton = "Try again"
    public static let dismissButton = "Dismiss"

    public static let confirmTitle = "Pair with this device?"
    public static let confirmSubtitle = "We'll link this Catlaser to your account and wipe any previous owner's link."
    public static let confirmDeviceIDLabel = "Device"
    public static let confirmButton = "Pair this Catlaser"
    public static let confirmCancelButton = "Cancel"

    /// Render a device identifier in a human-scannable form.
    ///
    /// The identifier that rides the QR is a slug drawn from
    /// `[A-Za-z0-9_-]{1..64}` (enforced by ``PairingCode.validateDeviceID``).
    /// Two cases, chosen by inspection:
    ///
    /// - If the slug already carries a structural separator (hyphen or
    ///   underscore) the device's firmware picked a human format; we
    ///   keep it byte-for-byte so a support ticket citing the printed
    ///   identifier can be cross-referenced verbatim.
    /// - Otherwise the slug is an undifferentiated alphanumeric run
    ///   (the common factory default). A run of 8+ characters is hard
    ///   to read aloud or compare at a glance; insert a regular space
    ///   every four characters so the user's eye can lock onto
    ///   four-character groups while committing to the pair. Under 8
    ///   characters the grouping gains nothing and would just add
    ///   visual noise.
    ///
    /// The inserted spaces are *display-only*. Every wire use of the
    /// device ID (the pair-exchange body, the settings-row `LabeledRow`,
    /// ``textSelection(.enabled)`` copy-paste) reads from the raw
    /// ``PairingCode.deviceID`` or ``PairedDevice.id`` string and is
    /// unaffected.
    public static func humanizedDeviceID(_ id: String) -> String {
        if id.contains("-") || id.contains("_") { return id }
        guard id.count >= 8 else { return id }
        var chunks: [String] = []
        var remaining = Substring(id)
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex,
                offsetBy: 4,
                limitedBy: remaining.endIndex,
            ) ?? remaining.endIndex
            chunks.append(String(remaining[remaining.startIndex ..< end]))
            remaining = remaining[end...]
        }
        return chunks.joined(separator: " ")
    }

    public static let connectionStateIdle = "Idle"
    public static let connectionStateWaitingForNetwork = "Waiting for network"
    public static let connectionStateConnected = "Connected"
    public static let connectionStateBackingOff = "Reconnecting…"

    public static let permissionNeededTitle = "Camera access needed"
    public static let permissionNeededSubtitle = "The camera is used only to read the QR code on your Catlaser. No video leaves your phone."
    public static let permissionRequestButton = "Allow camera"
    public static let permissionDeniedTitle = "Camera access denied"
    public static let permissionDeniedSubtitle = "Open Settings to enable camera access, or tap \"Enter code manually\" to finish pairing."
    public static let permissionRestrictedTitle = "Camera unavailable"
    public static let permissionRestrictedSubtitle = "Camera access is restricted on this device. Tap \"Enter code manually\" to finish pairing."
    public static let openSettingsButton = "Open Settings"

    // MARK: - Scanner overlay

    public static let scannerReticleAccessibility =
        "Position the QR code from your Catlaser inside the framed area."
    public static let scannerTorchOnButton = "Turn on flashlight"
    public static let scannerTorchOffButton = "Turn off flashlight"
    public static let scannerTorchOnAccessibility =
        "Turn on flashlight to read the QR code in low light"
    public static let scannerTorchOffAccessibility = "Turn off flashlight"

    // MARK: - Connection status pill (paired-flow tab overlay)

    public static let pillConnecting = "Connecting…"
    public static let pillReconnectingPrefix = "Reconnecting"
    public static let pillDisconnected = "Disconnected"
    public static let pillAccessibilityWaitingForNetwork =
        "Connection: waiting for network"
    public static let pillAccessibilityConnecting = "Connection: connecting"
    public static let pillAccessibilityReconnecting = "Connection: reconnecting"
    public static let pillAccessibilityFailedPrefix = "Connection failed."

    /// Pill copy for ``ConnectionState.connecting(attempt:)``. Suppresses
    /// the attempt count on the first try so a healthy connect doesn't
    /// surface scary "attempt 1" framing; subsequent attempts surface the
    /// counter so a user diagnosing flakiness has a number to point at.
    public static func pillConnectingLabel(attempt: Int) -> String {
        attempt <= 1
            ? pillConnecting
            : String(format: "%@ (attempt %d)…", pillReconnectingPrefix, attempt)
    }

    // MARK: - Connecting-screen (full-screen between paired + live)

    public static let connectingTitle = "Connecting to your Catlaser"
    public static let connectingSubtitle =
        "Your phone and device are talking. This usually takes a second or two."
    public static let waitingForNetworkTitle = "Waiting for network"
    public static let waitingForNetworkSubtitle =
        "We'll reconnect automatically once your phone is back online."
    public static let backingOffTitle = "Reconnecting to your Catlaser"
    public static let backingOffSubtitle =
        "Your device is reachable but the last attempt didn't land. Trying again…"
    public static let connectionFailedTitle = "Can't reach your Catlaser"

    public static func connectionStateLabel(_ state: ConnectionState) -> String {
        switch state {
        case .idle: connectionStateIdle
        case .waitingForNetwork: connectionStateWaitingForNetwork
        case let .connecting(attempt):
            "Connecting (attempt \(attempt))…"
        case .connected: connectionStateConnected
        case let .backingOff(_, attempt):
            "Reconnecting (attempt \(attempt))…"
        case let .failed(error):
            errorMessage(for: error)
        }
    }

    public static func errorMessage(for error: PairingError) -> String {
        switch error {
        case let .invalidCode(reason):
            return invalidCodeMessage(reason)
        case .missingSession:
            return "You're signed out. Sign back in to pair a Catlaser."
        case let .sessionExpired(message):
            // Distinct from `.missingSession`: the user has a stored
            // session but the server rejected it. The remediation is a
            // fresh sign-in — the pairing itself is intact and the UI
            // must not imply the Catlaser has been un-paired.
            if let message, !message.isEmpty {
                return "Your sign-in session ended. Sign in again to continue. (\(message))"
            }
            return "Your sign-in session ended. Sign in again to continue."
        case .codeAlreadyUsed:
            return "This pairing code has already been used. Generate a new QR on the Catlaser and try again."
        case .codeExpired:
            return "This pairing code has expired. Generate a new QR on the Catlaser and try again."
        case .codeNotFound:
            return "The server didn't recognise this pairing code. Generate a new QR on the Catlaser."
        case let .rateLimited(message):
            if let message, !message.isEmpty {
                return "Too many attempts. \(message)"
            }
            return "Too many attempts. Wait a minute and try again."
        case let .serverError(status, message):
            if let message, !message.isEmpty {
                return "Server error (\(status)): \(message)"
            }
            return "Server error (\(status)). Try again in a moment."
        case let .network(message):
            return "Network failure: \(message)"
        case let .invalidServerResponse(message):
            return "Unexpected server response: \(message)"
        case let .storage(message):
            return "Couldn't save pairing: \(message)"
        case let .attestation(message):
            return "Device attestation failed: \(message)"
        case .authRevoked:
            return "Your access to this Catlaser was revoked. Pair again to reconnect."
        }
    }

    private static func invalidCodeMessage(_ error: PairingCodeError) -> String {
        switch error {
        case .empty:
            "That QR is empty. Point the camera at the QR on your Catlaser."
        case .malformedURL:
            "That doesn't look like a Catlaser QR."
        case .wrongScheme, .wrongHost, .unexpectedPath:
            "That QR isn't a Catlaser pairing code."
        case .missingQueryItems, .missingCode, .missingDeviceID:
            "That QR is missing some information. Generate a new one on your Catlaser."
        case .duplicateQueryItem, .unexpectedQueryItem:
            "That QR looks tampered with. Generate a new one on your Catlaser."
        case .codeTooShort, .codeTooLong, .codeIllegalCharacter:
            "That pairing code is malformed."
        case .deviceIDTooLong, .deviceIDIllegalCharacter:
            "That device identifier is malformed."
        }
    }
}
