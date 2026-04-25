import CatLaserAuth
import CatLaserDesign
import CatLaserDevice
import CatLaserPairing
import CatLaserProto
import CatLaserPush
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Programmatic-navigation routes the Settings tab can push.
///
/// Used by ``MainTabView`` to deep-link tapped notifications past the
/// root Settings list and onto a specific destination — the
/// hopper-empty push tap, for instance, lands the user directly on
/// the refill instructions rather than dropping them at the top of
/// Settings to hunt for the row. Hashable because SwiftUI's
/// ``NavigationStack(path:)`` requires it.
enum SettingsRoute: Hashable {
    /// Refill-instructions destination. Reachable from a tap on the
    /// hopper row, or pushed automatically when a hopper-empty
    /// notification deep link arrives.
    case hopperDetail
}

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
    /// Live device-event fanout the Settings screen reads
    /// ``latestStatus`` from to render the hopper row. ``@Bindable``
    /// so SwiftUI observes ``latestStatus`` changes and re-renders the
    /// row on every device heartbeat; passed as a fresh instance on
    /// same-device reconnect (a new broker is minted per supervisor
    /// cycle, and PairedShell's ``@State`` reassignment propagates the
    /// swap through here).
    @Bindable var deviceEventBroker: DeviceEventBroker
    let authCoordinator: AuthCoordinator
    let appVersion: String
    let buildNumber: String
    let legalURLs: LegalURLs

    /// Two-way binding into the parent's ``NavigationStack`` path.
    /// ``MainTabView`` owns the array so a deep-linked push tap (e.g.
    /// hopper-empty) can append a ``SettingsRoute`` and have this
    /// view auto-push to the destination on first appearance. The
    /// view also writes through the binding when the user navigates
    /// back, keeping the parent's path in sync with the actual stack
    /// the user sees.
    @Binding var navigationPath: [SettingsRoute]

    /// Mutually-exclusive modal state.
    ///
    /// The five dialogs the Settings screen can surface are driven
    /// through a single optional enum rather than five independent
    /// ``Bool`` flags. Two properties follow from that choice:
    ///
    /// * The modals are mutually exclusive by construction — a second
    ///   tap on another destructive row while an earlier dialog is
    ///   still animating replaces rather than stacks. SwiftUI's
    ///   ``.confirmationDialog`` / ``.alert`` modifiers independently
    ///   cannot enforce this; each modifier sees only its own
    ///   ``isPresented`` binding, so two dialogs whose booleans both
    ///   went true at once could flash or stack depending on the iOS
    ///   version. The single-source enum closes that gap.
    /// * Each dialog's ``isPresented`` binding is a projection off
    ///   the enum that reads true iff the current case matches and
    ///   writes ``nil`` on dismiss. There is no way to open two
    ///   dialogs concurrently — the act of opening one closes the
    ///   others.
    private enum Dialog: Equatable {
        case confirmUnpair
        case confirmSignOut
        case signOutError(String)
        case confirmDeleteAccount
        case deleteAccountError(String)
    }

    @State private var dialog: Dialog?

    /// True while the ``deleteAccount()`` round-trip is in flight.
    /// Disables the destructive confirmation dialog's re-entry path
    /// and spins a row-level ``ProgressView`` on the account section
    /// so a slow network call cannot be double-tapped into two
    /// concurrent delete attempts (the server's attestation skew
    /// window would happily accept both).
    @State private var isDeletingAccount = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                pushSection
                deviceSection
                accountSection
                aboutSection
            }
            .navigationTitle(SettingsStrings.screenTitle)
            .scrollContentBackground(.hidden)
            .background(SemanticColor.background.ignoresSafeArea())
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .hopperDetail:
                    HopperRefillView(level: deviceEventBroker.latestStatus?.hopperLevel)
                }
            }
            .confirmationDialog(
                SettingsStrings.confirmUnpairTitle,
                isPresented: dialogBinding(.confirmUnpair),
                titleVisibility: .visible,
            ) {
                Button(SettingsStrings.confirmUnpairAction, role: .destructive) {
                    Haptics.warning.play()
                    dialog = nil
                    Task { await pairingViewModel.unpair() }
                }
                Button(SettingsStrings.cancelButton, role: .cancel) {}
            } message: {
                Text(SettingsStrings.confirmUnpairMessage)
            }
            .confirmationDialog(
                SettingsStrings.confirmSignOutTitle,
                isPresented: dialogBinding(.confirmSignOut),
                titleVisibility: .visible,
            ) {
                Button(SettingsStrings.confirmSignOutAction, role: .destructive) {
                    Haptics.warning.play()
                    dialog = nil
                    Task { await performSignOut() }
                }
                Button(SettingsStrings.cancelButton, role: .cancel) {}
            } message: {
                Text(SettingsStrings.confirmSignOutMessage)
            }
            .alert(
                SettingsStrings.signOutErrorTitle,
                isPresented: signOutErrorBinding,
            ) {
                Button(SettingsStrings.signOutErrorOK, role: .cancel) {}
            } message: {
                if case let .signOutError(message) = dialog {
                    Text(message)
                }
            }
            .confirmationDialog(
                SettingsStrings.confirmDeleteAccountTitle,
                isPresented: dialogBinding(.confirmDeleteAccount),
                titleVisibility: .visible,
            ) {
                Button(SettingsStrings.confirmDeleteAccountAction, role: .destructive) {
                    Haptics.warning.play()
                    dialog = nil
                    Task { await performDeleteAccount() }
                }
                Button(SettingsStrings.cancelButton, role: .cancel) {}
            } message: {
                Text(SettingsStrings.confirmDeleteAccountMessage)
            }
            .alert(
                SettingsStrings.deleteAccountErrorTitle,
                isPresented: deleteAccountErrorBinding,
            ) {
                Button(SettingsStrings.deleteAccountErrorOK, role: .cancel) {}
            } message: {
                if case let .deleteAccountError(message) = dialog {
                    Text(message)
                }
            }
        }
    }

    /// Bridge a confirmation-dialog's ``isPresented`` binding into
    /// the single-source ``dialog`` enum. The getter matches the
    /// enum case; the setter clears the enum on ``false`` and is a
    /// no-op on ``true`` (only the button handlers assign cases —
    /// SwiftUI never writes ``true`` through this binding itself).
    private func dialogBinding(_ target: Dialog) -> Binding<Bool> {
        Binding(
            get: { dialog == target },
            set: { isPresented in
                if !isPresented, dialog == target {
                    dialog = nil
                }
            },
        )
    }

    /// Projection for the sign-out-error alert. Payload-bearing
    /// cases need their own getter because ``Dialog.Equatable``
    /// compares the whole case including the associated value —
    /// a ``==`` check against a synthetic sentinel would miss real
    /// messages.
    private var signOutErrorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .signOutError = dialog { return true }
                return false
            },
            set: { isPresented in
                if !isPresented, case .signOutError = dialog {
                    dialog = nil
                }
            },
        )
    }

    private var deleteAccountErrorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .deleteAccountError = dialog { return true }
                return false
            },
            set: { isPresented in
                if !isPresented, case .deleteAccountError = dialog {
                    dialog = nil
                }
            },
        )
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
                NavigationLink(value: SettingsRoute.hopperDetail) {
                    HopperRow(level: deviceEventBroker.latestStatus?.hopperLevel)
                }
                Button(role: .destructive) {
                    dialog = .confirmUnpair
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
                dialog = .confirmSignOut
            } label: {
                Text(SettingsStrings.signOutButton)
            }
            .disabled(isDeletingAccount)
            .accessibilityLabel(Text(SettingsStrings.signOutButton))
            Button(role: .destructive) {
                dialog = .confirmDeleteAccount
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
            dialog = .signOutError(SettingsStrings.signOutErrorMessage(for: error))
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
            dialog = .deleteAccountError(SettingsStrings.deleteAccountErrorMessage(for: error))
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

/// Hopper-level row shown inside the Device section. Mirrors the
/// visual shape of ``LabeledRow`` — label on the leading edge, a
/// severity-tinted status word on the trailing edge — so the Device
/// section reads as one coherent stack rather than a labeled-content
/// sandwich around one custom widget. The trailing colour matches
/// the pattern ``PushSummaryRow`` uses: a healthy reading is secondary
/// text (steady-state, nothing to act on), ``low`` is the warning
/// tint, ``empty`` is destructive so a user glancing at Settings
/// reaches for the next refill before they next tap "Watch live"
/// and discover it the hard way.
///
/// A nil level — no heartbeat has arrived yet — renders a muted
/// "Waiting for device…" placeholder. That state is transient on
/// any healthy connection (the device heartbeats at 1–5 Hz), so the
/// row converges on a real value within the first few seconds of
/// the Settings tab being on screen.
private struct HopperRow: View {
    let level: Catlaser_App_V1_HopperLevel?

    var body: some View {
        LabeledContent(SettingsStrings.hopperLabel) {
            Text(SettingsStrings.hopperLevelLabel(level))
                .font(.body)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(SettingsStrings.hopperLabel))
        .accessibilityValue(Text(SettingsStrings.hopperLevelLabel(level)))
    }

    private var tint: Color {
        switch level {
        case .low:
            return SemanticColor.warning
        case .empty:
            return SemanticColor.destructive
        case .ok, .unspecified, .UNRECOGNIZED, .none:
            return SemanticColor.textSecondary
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

/// Refill-instructions destination pushed from the Settings ▸ Treat
/// hopper row, or auto-pushed from a hopper-empty notification deep
/// link.
///
/// Three sections, top to bottom:
///
/// 1. A status hero — current level rendered as a tinted pill, plus
///    a one-line headline that adapts to the level so a user with an
///    empty hopper reads "Refill needed" while a user with a full
///    hopper reads "All set." The hero is decorative — the numbered
///    steps below are the actionable content.
/// 2. Numbered "How to refill" steps. Each step is a single physical
///    action so a user can complete one before scanning to the next.
/// 3. A "What to use" callout with the supported treat shape. Avoids
///    a real failure mode (oversized treats jamming the dispenser)
///    that the support inbox would otherwise see repeatedly.
///
/// Footer reassures the user that the level updates automatically on
/// the next play session — they do not have to "tell" the app
/// anything.
private struct HopperRefillView: View {
    let level: Catlaser_App_V1_HopperLevel?

    var body: some View {
        Form {
            Section {
                HopperHeroRow(level: level)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                Text(SettingsStrings.hopperRefillIntro)
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(SettingsStrings.hopperRefillStepsTitle) {
                ForEach(Array(SettingsStrings.hopperRefillSteps.enumerated()), id: \.offset) { index, step in
                    HopperStepRow(number: index + 1, body: step)
                }
            }

            Section(SettingsStrings.hopperRefillSafetyTitle) {
                Text(SettingsStrings.hopperRefillSafetyBody)
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(SettingsStrings.hopperRefillFooter)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(SemanticColor.background.ignoresSafeArea())
        .navigationTitle(SettingsStrings.hopperRefillScreenTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Hero status pill rendered at the top of ``HopperRefillView``.
/// Matches the severity-tint pattern the row in Settings already
/// uses — a healthy reading is muted, ``low`` is the warning tint,
/// ``empty`` is destructive — so the user sees a continuous visual
/// language when they navigate from row to detail.
private struct HopperHeroRow: View {
    let level: Catlaser_App_V1_HopperLevel?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsStrings.hopperLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SemanticColor.textSecondary)
                    .textCase(.uppercase)
                Text(SettingsStrings.hopperLevelLabel(level))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "\(SettingsStrings.hopperLabel), \(SettingsStrings.hopperLevelLabel(level))",
        ))
    }

    private var tint: Color {
        switch level {
        case .empty: SemanticColor.destructive
        case .low: SemanticColor.warning
        case .ok: SemanticColor.success
        case .unspecified, .UNRECOGNIZED, .none: SemanticColor.textSecondary
        }
    }

    private var iconName: String {
        switch level {
        case .empty: "exclamationmark.octagon.fill"
        case .low: "exclamationmark.triangle.fill"
        case .ok: "checkmark.seal.fill"
        case .unspecified, .UNRECOGNIZED, .none: "hourglass"
        }
    }
}

/// One numbered step row inside the refill instructions list.
/// Numbers render in an accent-tinted disc on the leading edge so the
/// list reads as a sequence, not a bullet pile. Body text wraps
/// across lines via ``fixedSize`` so a longer step (or larger Dynamic
/// Type setting) does not get truncated.
private struct HopperStepRow: View {
    let number: Int
    let body: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(SemanticColor.accent)
                Text("\(number)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            Text(self.body)
                .font(.callout)
                .foregroundStyle(SemanticColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number). \(self.body)"))
    }
}
