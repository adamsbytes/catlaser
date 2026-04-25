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
///
/// ## Recovery affordances
///
/// A user whose connect is taking longer than expected gets two
/// non-destructive remediations BEFORE the destructive Unpair button
/// becomes the prominent option:
///
/// 1. After ``troubleshootingDelay`` seconds, a "Trouble connecting?"
///    help block fades in with three concrete checks (power, internet,
///    Wi-Fi). The supervisor is still actively retrying — this is help,
///    not failure.
/// 2. The Unpair button stays available but is rendered as a tertiary
///    text link, not a chunky pill. A frustrated user who taps it on
///    impulse is still gated by ``SettingsStrings.confirmUnpair``, but
///    the visual hierarchy now matches the cost: try the checks first,
///    unpair as a last resort.
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

    /// Whether the inline troubleshooting block has been revealed by
    /// the auto-show timer. Starts ``false`` and flips to ``true``
    /// after ``troubleshootingDelay``; never flips back. A user who
    /// stays on this screen long enough to read the timer needs the
    /// help, and re-hiding it as soon as the supervisor retries would
    /// be a flicker rather than an improvement.
    @State private var showTroubleshooting = false

    /// Delay before the inline help block fades in. Long enough to
    /// stay invisible on a healthy connect (the median connect on the
    /// test fleet lands well under three seconds) and short enough
    /// that a stuck user is not staring at a bare spinner. Tuned by
    /// hand against a sluggish-cellular launch.
    private static let troubleshootingDelay: Duration = .seconds(4)

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
                if showTroubleshooting {
                    troubleshootingBlock
                        .padding(.top, 12)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }
                Spacer()
                // De-emphasised escape hatch. Plain text rather than
                // a filled pill so the visual hierarchy reads as
                // "this is the last-resort option, not the recommended
                // one" — recovery flows the user through the
                // troubleshooting block first. The destructive
                // confirmation dialog stays unchanged: the safety
                // gate is the dialog, not the styling.
                Button {
                    confirmUnpair = true
                } label: {
                    Text(PairingStrings.unpairButton)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SemanticColor.destructive)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
                .accessibilityLabel(Text(PairingStrings.unpairButton))
            }
            .animation(.easeInOut(duration: 0.25), value: showTroubleshooting)
        }
        .task {
            // Auto-reveal the troubleshooting block after a short
            // delay. Cancellation-aware: SwiftUI tears the task down
            // when the view leaves the hierarchy (the supervisor
            // landed on .connected, the user navigated away, etc.),
            // so the state write only fires while the view is still
            // on screen. A second mount restarts the timer because
            // the .task lifecycle is per-mount.
            try? await Task.sleep(for: Self.troubleshootingDelay)
            guard !Task.isCancelled else { return }
            showTroubleshooting = true
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

    /// Inline help rendered after ``troubleshootingDelay``. A title
    /// row plus a bulleted list of the three most-likely-cause checks
    /// the user can run without leaving the app. Bulletted with a
    /// system glyph rather than a Unicode dot so the alignment stays
    /// stable under Dynamic Type and across locales.
    private var troubleshootingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PairingStrings.connectingHelpTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PairingStrings.connectingHelpBullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(SemanticColor.accent)
                            .accessibilityHidden(true)
                        Text(bullet)
                            .font(.footnote)
                            .foregroundStyle(SemanticColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(troubleshootingAccessibilityLabel))
    }

    /// Combined accessibility label for the troubleshooting block —
    /// VoiceOver users hear the title followed by every bullet as one
    /// announcement instead of four separate fragments.
    private var troubleshootingAccessibilityLabel: String {
        ([PairingStrings.connectingHelpTitle] + PairingStrings.connectingHelpBullets)
            .joined(separator: ". ")
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
