import Foundation

/// Localised strings for the live-view screen.
///
/// Kept alongside the view model so tests can assert on the exact
/// user-facing message rendered for a given `LiveViewError`. The
/// existing codebase already localises this way in
/// `CatLaserApp/SignInStrings.swift`; follow the same pattern so the
/// localisation surface is one-stop.
public enum LiveViewStrings {
    public static let disconnectedTitle = NSLocalizedString(
        "live.disconnected.title",
        value: "Live view is off",
        comment: "Title shown on the live-view screen when no stream is active.",
    )

    public static let disconnectedSubtitle = NSLocalizedString(
        "live.disconnected.subtitle",
        value: "Tap Watch live to see what your cat is up to right now.",
        comment: "Subtitle shown on the live-view screen when no stream is active.",
    )

    /// Variant subtitle shown on the disconnected screen right after
    /// the user cancelled the Face ID / passcode prompt. A common
    /// cause of cancel is a Face ID misfire (sunglasses, bad angle,
    /// wet fingers); the copy tells the user the system prompt was
    /// the blocker, not a tap on "Watch live" that did nothing.
    public static let disconnectedAuthCancelledSubtitle = NSLocalizedString(
        "live.disconnected.auth_cancelled.subtitle",
        value: "Couldn't confirm your identity. Tap Watch live to try again.",
        comment: "Subtitle shown after the user cancelled the biometric / passcode prompt on the live-view screen.",
    )

    /// Variant subtitle shown on the disconnected screen right after
    /// a network-class drop (wifi roam, cellular hiccup, app
    /// suspended in the background so iOS closed the socket). The
    /// VM lands in ``.disconnected`` rather than ``.failed`` for
    /// this class because a routine background trip shouldn't look
    /// like a crash; this copy tells the user the feed paused on
    /// its own and reassures them a single tap resumes it.
    public static let disconnectedNetworkDropSubtitle = NSLocalizedString(
        "live.disconnected.network_drop.subtitle",
        value: "Stream paused when your phone lost the connection. Tap Watch live to resume.",
        comment: "Subtitle shown after a network-class drop while a live stream was active.",
    )

    public static let watchLiveButton = NSLocalizedString(
        "live.watch_live.button",
        value: "Watch live",
        comment: "Primary call-to-action to start a live video stream.",
    )

    public static let requestingOfferLabel = NSLocalizedString(
        "live.requesting.label",
        value: "Contacting device…",
        comment: "Spinner label shown while the app requests a stream offer from the device.",
    )

    public static let connectingLabel = NSLocalizedString(
        "live.connecting.label",
        value: "Connecting to stream…",
        comment: "Spinner label shown while the app is dialling LiveKit.",
    )

    public static let disconnectingLabel = NSLocalizedString(
        "live.disconnecting.label",
        value: "Stopping stream…",
        comment: "Spinner label shown while the app is tearing the stream down.",
    )

    public static let stopButton = NSLocalizedString(
        "live.stop.button",
        value: "Stop",
        comment: "Button that ends the live stream.",
    )

    /// Button shown beneath the connecting spinner so a user who
    /// taps "Watch live" and gets stuck on a slow handshake (slow
    /// cellular, sluggish device, server hiccup) can back out without
    /// waiting for the 30-second connect watchdog. Uses ``stop()``
    /// internally — the VM idempotently tears down whatever has been
    /// set up so far (offer request in flight, partial LiveKit dial,
    /// armed timeout task) and returns to ``.disconnected``.
    public static let cancelConnectingButton = NSLocalizedString(
        "live.connecting.cancel.button",
        value: "Cancel",
        comment: "Button shown under the connecting spinner that backs out of an in-flight stream connect.",
    )

    public static let failedTitle = NSLocalizedString(
        "live.failed.title",
        value: "Couldn't start live view",
        comment: "Error-state title on the live-view screen.",
    )

    public static let dismissButton = NSLocalizedString(
        "live.dismiss.button",
        value: "Dismiss",
        comment: "Dismiss an error banner on the live-view screen.",
    )

    public static let retryButton = NSLocalizedString(
        "live.retry.button",
        value: "Try again",
        comment: "Retry a failed live-view connect.",
    )

    public static let videoAccessibilityLabel = NSLocalizedString(
        "live.video.accessibility",
        value: "Live video from your cat laser device",
        comment: "VoiceOver label for the live video view.",
    )

    /// Render a `LiveViewError` into a human-readable message.
    public static func message(for error: LiveViewError) -> String {
        switch error {
        case .deviceError:
            // The device-side message is a developer artefact — it
            // may carry internal Python tracebacks or protocol-level
            // diagnostic text the user has no use for. Surface the
            // stable generic copy and rely on observability for the
            // server-supplied detail.
            return deviceGenericMessage
        case .streamOfferMissing:
            return NSLocalizedString(
                "live.error.offer_missing",
                value: "The device returned an unexpected response. Please try again.",
                comment: "Error shown when the device returned the wrong oneof in response to StartStreamRequest.",
            )
        case .streamOfferInvalid:
            return NSLocalizedString(
                "live.error.offer_invalid",
                value: "The device sent an invalid stream offer. Please try again.",
                comment: "Error shown when the StreamOffer did not parse as valid credentials.",
            )
        case .notConnected:
            return NSLocalizedString(
                "live.error.not_connected",
                value: "Your phone isn't connected to the device. Check that both are on the same network.",
                comment: "Error shown when the device TCP channel is closed.",
            )
        case .transportFailure:
            return NSLocalizedString(
                "live.error.transport",
                value: "The connection to your device dropped. Please try again.",
                comment: "Error shown when the device TCP channel errored.",
            )
        case .timeout:
            return NSLocalizedString(
                "live.error.timeout",
                value: "The device didn't respond in time. Please try again.",
                comment: "Error shown when the device did not reply within the request timeout.",
            )
        case .streamConnectFailed:
            return NSLocalizedString(
                "live.error.stream_connect",
                value: "Couldn't connect to the video stream. Please try again.",
                comment: "Error shown when the LiveKit connect / subscribe failed.",
            )
        case .streamConnectTimeout:
            return NSLocalizedString(
                "live.error.stream_connect_timeout",
                value: "The video stream took too long to start. Please try again.",
                comment: "Error shown when the LiveKit connect watchdog timed out.",
            )
        case .unexpectedPublisher:
            return NSLocalizedString(
                "live.error.unexpected_publisher",
                value: "Your Catlaser sent the video from an unexpected place. Stop the stream and, if this keeps happening, unpair and pair again from Settings.",
                comment: "Error shown when a non-device participant published into the room.",
            )
        case .streamDropped:
            return NSLocalizedString(
                "live.error.stream_dropped",
                value: "The stream ended unexpectedly. Please try again.",
                comment: "Error shown when the LiveKit server dropped the stream.",
            )
        case .authenticationRequired:
            return NSLocalizedString(
                "live.error.authentication_required",
                value: "Confirm with Face ID or your passcode to watch live video.",
                comment: "Error shown when the pre-stream biometric gate refused.",
            )
        case .internalFailure:
            return deviceGenericMessage
        }
    }

    private static let deviceGenericMessage = NSLocalizedString(
        "live.error.generic",
        value: "Something went wrong talking to your Catlaser. Try again in a moment.",
        comment: "Generic error message on the live-view screen.",
    )
}
