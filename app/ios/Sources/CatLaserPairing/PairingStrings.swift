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
