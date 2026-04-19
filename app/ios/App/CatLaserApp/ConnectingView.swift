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

    /// Drives the destructive confirmation dialog. The Unpair button
    /// on this screen is reachable while the supervisor is mid-
    /// connect; users frustrated by a slow handshake have been
    /// observed to tap Unpair impulsively. The dialog matches the
    /// pattern Settings uses (``SettingsView.confirmUnpair``) so the
    /// destructive verb is gated by an explicit second confirmation
    /// regardless of which surface the user reached it from.
    @State private var confirmUnpair = false

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
                Button {
                    confirmUnpair = true
                } label: {
                    Text(PairingStrings.unpairButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(SemanticColor.elevatedFill, in: Capsule())
                        .foregroundStyle(SemanticColor.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
                .accessibilityLabel(Text(PairingStrings.unpairButton))
            }
        }
        .confirmationDialog(
            SettingsStrings.confirmUnpairTitle,
            isPresented: $confirmUnpair,
            titleVisibility: .visible,
        ) {
            Button(SettingsStrings.confirmUnpairAction, role: .destructive) {
                Haptics.warning.play()
                onUnpair()
            }
            Button(SettingsStrings.cancelButton, role: .cancel) {}
        } message: {
            Text(SettingsStrings.confirmUnpairMessage)
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
        case .waitingForNetwork: PairingStrings.waitingForNetworkTitle
        case .backingOff: PairingStrings.backingOffTitle
        case .failed: PairingStrings.connectionFailedTitle
        default: PairingStrings.connectingTitle
        }
    }

    private var subtitle: String {
        switch connectionState {
        case .waitingForNetwork:
            PairingStrings.waitingForNetworkSubtitle
        case .backingOff:
            PairingStrings.backingOffSubtitle
        case let .failed(error):
            PairingStrings.errorMessage(for: error)
        default:
            PairingStrings.connectingSubtitle
        }
    }

    private var showsProgress: Bool {
        switch connectionState {
        case .failed: false
        default: true
        }
    }
}
