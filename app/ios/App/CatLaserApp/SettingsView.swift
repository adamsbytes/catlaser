import CatLaserAuth
import CatLaserDesign
import CatLaserPairing
import CatLaserPush
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Settings tab.
///
/// Holds the low-frequency controls that would be noise on the
/// primary tabs: push authorisation, unpair, sign out, and version
/// info. Every action routes through an existing view model or
/// coordinator — the view owns no persistent state of its own.
///
/// The Push section embeds ``PushView`` rather than re-implementing
/// its state machine; the result is that the primer / denied / error
/// panes render inline in the settings scroll view exactly the same
/// way they would on a standalone screen.
struct SettingsView: View {
    @Bindable var pushViewModel: PushViewModel
    @Bindable var pairingViewModel: PairingViewModel
    let authCoordinator: AuthCoordinator
    let appVersion: String
    let buildNumber: String
    let legalURLs: LegalURLs

    /// Confirmation sheet state for destructive actions. Both default
    /// to false; a tap on the row presents the respective dialog.
    @State private var confirmUnpair = false
    @State private var confirmSignOut = false
    @State private var signOutError: String?
    @State private var confirmDeleteAccount = false
    @State private var deleteAccountError: String?
    /// True while the ``deleteAccount()`` round-trip is in flight.
    /// Disables the destructive confirmation dialog's re-entry path
    /// and spins a row-level ``ProgressView`` on the account section
    /// so a slow network call cannot be double-tapped into two
    /// concurrent delete attempts (the server's attestation skew
    /// window would happily accept both).
    @State private var isDeletingAccount = false

    var body: some View {
        NavigationStack {
            Form {
                pushSection
                deviceSection
                accountSection
                aboutSection
            }
            .navigationTitle(SettingsStrings.screenTitle)
            .scrollContentBackground(.hidden)
            .background(SemanticColor.background.ignoresSafeArea())
            .confirmationDialog(
                SettingsStrings.confirmUnpairTitle,
                isPresented: $confirmUnpair,
                titleVisibility: .visible,
            ) {
                Button(SettingsStrings.confirmUnpairAction, role: .destructive) {
                    Haptics.warning.play()
                    Task { await pairingViewModel.unpair() }
                }
                Button(SettingsStrings.cancelButton, role: .cancel) {}
            } message: {
                Text(SettingsStrings.confirmUnpairMessage)
            }
            .confirmationDialog(
                SettingsStrings.confirmSignOutTitle,
                isPresented: $confirmSignOut,
                titleVisibility: .visible,
            ) {
                Button(SettingsStrings.confirmSignOutAction, role: .destructive) {
                    Haptics.warning.play()
                    Task { await performSignOut() }
                }
                Button(SettingsStrings.cancelButton, role: .cancel) {}
            } message: {
                Text(SettingsStrings.confirmSignOutMessage)
            }
            .alert(
                SettingsStrings.signOutErrorTitle,
                isPresented: Binding(
                    get: { signOutError != nil },
                    set: { if !$0 { signOutError = nil } },
                ),
            ) {
                Button(SettingsStrings.signOutErrorOK, role: .cancel) {}
            } message: {
                if let signOutError {
                    Text(signOutError)
                }
            }
            .confirmationDialog(
                SettingsStrings.confirmDeleteAccountTitle,
                isPresented: $confirmDeleteAccount,
                titleVisibility: .visible,
            ) {
                Button(SettingsStrings.confirmDeleteAccountAction, role: .destructive) {
                    Haptics.warning.play()
                    Task { await performDeleteAccount() }
                }
                Button(SettingsStrings.cancelButton, role: .cancel) {}
            } message: {
                Text(SettingsStrings.confirmDeleteAccountMessage)
            }
            .alert(
                SettingsStrings.deleteAccountErrorTitle,
                isPresented: Binding(
                    get: { deleteAccountError != nil },
                    set: { if !$0 { deleteAccountError = nil } },
                ),
            ) {
                Button(SettingsStrings.deleteAccountErrorOK, role: .cancel) {}
            } message: {
                if let deleteAccountError {
                    Text(deleteAccountError)
                }
            }
        }
    }

    // MARK: - Sections

    private var pushSection: some View {
        Section(SettingsStrings.notificationsSection) {
            // Compact summary row. Previously this section embedded the
            // full ``PushView`` in a bounded-height Form row, which
            // collapsed the push view's top/bottom ``Spacer``s and
            // produced a cramped layout on-device. The full
            // primer / denied / registered / failed surface now lives
            // behind a ``NavigationLink`` destination where the
            // push view has the unbounded vertical space it was
            // designed for; the settings row surfaces the state at a
            // glance so a user can triage "is my push working?"
            // without navigating.
            NavigationLink {
                PushView(viewModel: pushViewModel)
                    .navigationTitle(SettingsStrings.notificationsScreenTitle)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            } label: {
                PushSummaryRow(state: pushViewModel.state)
            }
            .accessibilityLabel(Text(SettingsStrings.notificationsRowLabel))
            .accessibilityValue(Text(PushSummaryRow.statusText(for: pushViewModel.state)))
        }
    }

    private var deviceSection: some View {
        Section(SettingsStrings.deviceSection) {
            if case let .paired(device) = pairingViewModel.phase {
                LabeledRow(label: SettingsStrings.deviceNameLabel, value: deviceDisplayName(device))
                LabeledRow(label: SettingsStrings.deviceIDLabel, value: device.id, monospaced: true)
                LabeledRow(
                    label: SettingsStrings.deviceStatusLabel,
                    value: PairingStrings.connectionStateLabel(pairingViewModel.connectionState),
                )
                Button(role: .destructive) {
                    confirmUnpair = true
                } label: {
                    Text(PairingStrings.unpairButton)
                }
                .accessibilityLabel(Text(PairingStrings.unpairButton))
            } else {
                Text(SettingsStrings.deviceNotPaired)
                    .foregroundStyle(SemanticColor.textSecondary)
            }
        }
    }

    private var accountSection: some View {
        Section(SettingsStrings.accountSection) {
            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Text(SettingsStrings.signOutButton)
            }
            .disabled(isDeletingAccount)
            .accessibilityLabel(Text(SettingsStrings.signOutButton))
            Button(role: .destructive) {
                confirmDeleteAccount = true
            } label: {
                HStack {
                    Text(SettingsStrings.deleteAccountButton)
                    Spacer()
                    if isDeletingAccount {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(isDeletingAccount)
            .accessibilityLabel(Text(SettingsStrings.deleteAccountButton))
        }
    }

    private var aboutSection: some View {
        Section(SettingsStrings.aboutSection) {
            LabeledRow(label: SettingsStrings.versionLabel, value: appVersion)
            LabeledRow(label: SettingsStrings.buildLabel, value: buildNumber)
            // ``Link`` opens the URL in the user's default browser
            // (system Safari by default). We deliberately do NOT use
            // an in-app ``SFSafariViewController`` wrapper here: legal
            // documents are reference material, often read alongside
            // other sources, and routing through Safari lets the user
            // share the URL, open it in a different browser, or leave
            // a tab open while returning to the app.
            Link(destination: legalURLs.privacyPolicy) {
                LinkRow(label: SettingsStrings.privacyPolicyRow)
            }
            .accessibilityLabel(Text(SettingsStrings.privacyPolicyRow))
            Link(destination: legalURLs.termsOfService) {
                LinkRow(label: SettingsStrings.termsOfServiceRow)
            }
            .accessibilityLabel(Text(SettingsStrings.termsOfServiceRow))
        }
    }

    // MARK: - Helpers

    private func deviceDisplayName(_ device: PairedDevice) -> String {
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? SettingsStrings.deviceFallbackName : name
    }

    @MainActor
    private func performSignOut() async {
        do {
            try await authCoordinator.signOut()
        } catch {
            // Local state is wiped regardless of the server call's
            // outcome (see AuthCoordinator.signOut docstring); we
            // surface a presentable sentence — never the raw error
            // description, which would leak Swift's structured error
            // type into the UI. The lifecycle observer still fires on
            // throw, so the app still returns to the sign-in flow.
            signOutError = SettingsStrings.signOutErrorMessage(for: error)
        }
    }

    @MainActor
    private func performDeleteAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await authCoordinator.deleteAccount()
            // Success: the coordinator has wiped local state and
            // notified lifecycle observers. The app shell's own
            // ``sessionDidSignOut`` hook routes us back to sign-in,
            // so there is no further view-layer work to do.
        } catch {
            // Failure: local state is intentionally NOT wiped (see
            // ``AuthCoordinator/deleteAccount`` docstring). Surface
            // a presentable sentence so the user understands the
            // server-side deletion didn't land and they can retry.
            deleteAccountError = SettingsStrings.deleteAccountErrorMessage(for: error)
        }
    }
}

/// Two-column label row used by the device / about sections. Keeps
/// typography consistent with SwiftUI's `LabeledContent` while
/// adding the ``.textSelection(.enabled)`` affordance for the
/// monospaced device-ID row so users can copy it for support.
private struct LabeledRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(SemanticColor.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Row label for a ``Link`` inside a ``Form`` section. Reproduces
/// the native list-row affordance that ``Link`` does not style by
/// default when nested inside a ``Form`` — label on the leading
/// edge, a trailing `arrow.up.forward.square` glyph that matches
/// Apple's own Settings app convention for "this opens in an
/// external browser." ``contentShape`` makes the whole row
/// tappable (the default ``Link`` tap target is only the label
/// text's intrinsic size).
private struct LinkRow: View {
    let label: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(SemanticColor.textPrimary)
            Spacer()
            Image(systemName: "arrow.up.forward.square")
                .font(.body)
                .foregroundStyle(SemanticColor.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// Compact status row surfaced at the top of Settings → Notifications.
/// Mirrors the Apple Settings convention: a label on the leading edge,
/// a status value on the trailing edge tinted by severity, and the
/// NavigationLink chevron (added automatically by SwiftUI when this
/// row is used as a ``NavigationLink`` label). The status text is
/// derived from the VM's state machine; a dedicated static helper
/// exposes the same mapping for the accessibility value so VoiceOver
/// users hear the same summary.
private struct PushSummaryRow: View {
    let state: PushRegistrationState

    var body: some View {
        HStack {
            Text(SettingsStrings.notificationsRowLabel)
                .foregroundStyle(SemanticColor.textPrimary)
            Spacer()
            if case .requestingAuthorization = state {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            } else if case .awaitingAPNsToken = state {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            } else if case .registering = state {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
            Text(Self.statusText(for: state))
                .foregroundStyle(Self.statusTint(for: state))
        }
    }

    /// Map the VM's state into the short status word shown on the
    /// trailing edge of the row. Exposed ``static`` so the Settings
    /// view's accessibility value can use the same mapping without
    /// duplicating the switch.
    static func statusText(for state: PushRegistrationState) -> String {
        switch state {
        case .idle, .postponed:
            SettingsStrings.notificationsStatusOff
        case .requestingAuthorization, .awaitingAPNsToken, .registering:
            SettingsStrings.notificationsStatusConfiguring
        case .registered:
            SettingsStrings.notificationsStatusOn
        case .authorizationDenied:
            SettingsStrings.notificationsStatusDenied
        case .failed:
            SettingsStrings.notificationsStatusNeedsAttention
        }
    }

    /// Severity tint for the trailing status word. "On" reads as
    /// success, "Denied" and "Needs attention" as warning, everything
    /// else as secondary text.
    private static func statusTint(for state: PushRegistrationState) -> Color {
        switch state {
        case .registered:
            SemanticColor.success
        case .authorizationDenied, .failed:
            SemanticColor.warning
        case .idle, .postponed, .requestingAuthorization,
             .awaitingAPNsToken, .registering:
            SemanticColor.textSecondary
        }
    }
}
