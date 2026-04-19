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
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: visibleStatus?.label,
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
                label: PairingStrings.connectionStateWaitingForNetwork,
                tint: SemanticColor.warning,
                accessibilityLabel: PairingStrings.pillAccessibilityWaitingForNetwork,
            )
        case let .connecting(attempt):
            Status(
                label: PairingStrings.pillConnectingLabel(attempt: attempt),
                tint: SemanticColor.warning,
                accessibilityLabel: PairingStrings.pillAccessibilityConnecting,
            )
        case .backingOff:
            Status(
                label: PairingStrings.connectionStateBackingOff,
                tint: SemanticColor.warning,
                accessibilityLabel: PairingStrings.pillAccessibilityReconnecting,
            )
        case let .failed(error):
            Status(
                label: PairingStrings.pillDisconnected,
                tint: SemanticColor.destructive,
                accessibilityLabel:
                    PairingStrings.pillAccessibilityFailedPrefix + " " + PairingStrings.errorMessage(for: error),
            )
        }
    }

    private struct Status {
        let label: String
        let tint: Color
        let accessibilityLabel: String
    }
}
