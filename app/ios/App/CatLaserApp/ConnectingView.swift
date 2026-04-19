import CatLaserDesign
import CatLaserPairing
import SwiftUI

/// Shown in the brief window between "paired device loaded from
/// Keychain" and the first ``ConnectionState/connected(_:)`` event
/// from the supervisor.
///
/// On a fresh launch of a paired device the ``ConnectionManager``
/// passes through
/// ``ConnectionState/idle`` → ``connecting(attempt:1)`` →
/// ``connected``. On a flaky network it may also settle into
/// ``waitingForNetwork`` or ``backingOff`` before finally connecting.
/// This view renders the transient path so the user never lands on
/// an empty ``MainTabView`` with every tab spinning.
///
/// When the supervisor reports a terminal ``failed(authRevoked)`` the
/// paired shell has already torn down the pairing and routed the
/// user back to the QR flow; this view never has to handle that
/// path.
struct ConnectingView: View {
    let connectionState: ConnectionState
    let onUnpair: () -> Void

    var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: iconName)
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(iconTint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if showsProgress {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                Spacer()
                Button(action: onUnpair) {
                    Text(PairingStrings.unpairButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(SemanticColor.elevatedFill, in: Capsule())
                        .foregroundStyle(SemanticColor.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
        }
    }

    private var iconName: String {
        switch connectionState {
        case .waitingForNetwork: "wifi.exclamationmark"
        case .backingOff, .failed: "bolt.horizontal.circle"
        default: "antenna.radiowaves.left.and.right"
        }
    }

    private var iconTint: Color {
        switch connectionState {
        case .failed: SemanticColor.destructive
        case .waitingForNetwork, .backingOff: SemanticColor.warning
        default: SemanticColor.accent
        }
    }

    private var title: String {
        switch connectionState {
        case .waitingForNetwork: "Waiting for network"
        case .backingOff: "Reconnecting to your Catlaser"
        case .failed: "Can't reach your Catlaser"
        default: "Connecting to your Catlaser"
        }
    }

    private var subtitle: String {
        switch connectionState {
        case .waitingForNetwork:
            "We'll reconnect automatically once your phone is back online."
        case .backingOff:
            "Your device is reachable but the last attempt didn't land. Trying again…"
        case let .failed(error):
            PairingStrings.errorMessage(for: error)
        default:
            "Your phone and device are talking. This usually takes a second or two."
        }
    }

    private var showsProgress: Bool {
        switch connectionState {
        case .failed: false
        default: true
        }
    }
}
