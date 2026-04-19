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

    /// Confirmation sheet state for destructive actions. Both default
    /// to false; a tap on the row presents the respective dialog.
    @State private var confirmUnpair = false
    @State private var confirmSignOut = false
    @State private var signOutError: String?

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
        }
    }

    // MARK: - Sections

    private var pushSection: some View {
        Section(SettingsStrings.notificationsSection) {
            // Embedded full push view. The VM's state machine renders
            // whichever pane is appropriate (primer / registered /
            // denied / failed); inside a Form section it sits as one
            // tall row.
            PushView(viewModel: pushViewModel)
                .frame(minHeight: 220)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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
            .accessibilityLabel(Text(SettingsStrings.signOutButton))
        }
    }

    private var aboutSection: some View {
        Section(SettingsStrings.aboutSection) {
            LabeledRow(label: SettingsStrings.versionLabel, value: appVersion)
            LabeledRow(label: SettingsStrings.buildLabel, value: buildNumber)
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
