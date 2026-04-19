import CatLaserDesign
import CatLaserPairing
import SwiftUI

/// Small top-of-screen pill that surfaces the current
/// ``ConnectionState`` to users on any paired-flow tab (Live,
/// History, Schedule, Settings).
///
/// Hidden when connected (the happy path) to avoid a persistent
/// badge that trains the eye to ignore. Visible — subtle but
/// noticeable — for any non-connected state so the user never
/// asks "is this screen broken or is my device offline?".
///
/// Reduce-motion users get no fade; everybody else gets a 0.2s
/// opacity transition that matches the pattern every other screen
/// in the app uses.
struct ConnectionStatusPill: View {
    let state: ConnectionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let status = visibleStatus {
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(status.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SemanticColor.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(SemanticColor.separator.opacity(0.5), lineWidth: 0.5),
                )
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(status.accessibilityLabel))
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        // Animate on the visual category (``Kind``), NOT on the rendered
        // label. Keying on the label would crossfade the pill on every
        // attempt-counter increment ("Reconnecting (attempt 2)…" →
        // "Reconnecting (attempt 3)…"), producing a visible tick on
        // every supervisor backoff retry that the situation does not
        // warrant. Keying on the kind means the pill only animates when
        // it actually appears, disappears, or shifts category.
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: visibleStatus?.kind,
        )
    }

    /// Returns nil when the pill should be hidden (connected / idle
    /// pre-start). Returns a rendered status otherwise.
    private var visibleStatus: Status? {
        switch state {
        case .connected:
            nil
        case .idle:
            // Pre-start or post-stop: no supervisor attached yet.
            // The paired-flow views always start a supervisor on
            // appear, so idle here is transient and not worth a
            // badge.
            nil
        case .waitingForNetwork:
            Status(
                kind: .waitingForNetwork,
                label: PairingStrings.connectionStateWaitingForNetwork,
                tint: SemanticColor.warning,
                accessibilityLabel: PairingStrings.pillAccessibilityWaitingForNetwork,
            )
        case let .connecting(attempt):
            Status(
                kind: .connecting,
                label: PairingStrings.pillConnectingLabel(attempt: attempt),
                tint: SemanticColor.warning,
                accessibilityLabel: PairingStrings.pillAccessibilityConnecting,
            )
        case .backingOff:
            Status(
                kind: .backingOff,
                label: PairingStrings.connectionStateBackingOff,
                tint: SemanticColor.warning,
                accessibilityLabel: PairingStrings.pillAccessibilityReconnecting,
            )
        case let .failed(error):
            Status(
                kind: .failed,
                label: PairingStrings.pillDisconnected,
                tint: SemanticColor.destructive,
                accessibilityLabel:
                    PairingStrings.pillAccessibilityFailedPrefix + " " + PairingStrings.errorMessage(for: error),
            )
        }
    }

    /// Stable visual category for the pill. The animation modifier
    /// keys on this so a counter change inside ``connecting`` /
    /// ``backingOff`` does not trigger a crossfade — only a true
    /// category transition (or the pill appearing / disappearing
    /// entirely) does.
    private enum Kind: Equatable {
        case waitingForNetwork
        case connecting
        case backingOff
        case failed
    }

    private struct Status {
        let kind: Kind
        let label: String
        let tint: Color
        let accessibilityLabel: String
    }
}
