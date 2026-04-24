#if canImport(SwiftUI)
import CatLaserDesign
import SwiftUI

/// First-launch consent screen.
///
/// Presented once (on first install, and again if ``ConsentStore``'s
/// versioned key has been rotated). Two toggles, a privacy footnote,
/// and a Continue button. Defaults are both OFF — the only posture
/// that survives GDPR / App Store "no pre-checked consent" scrutiny.
/// The subtitle names the opt-out-by-default default explicitly so
/// the user is never confused about which direction of the switch is
/// the deliberate choice; the Continue button always advances,
/// committing whatever the toggles currently are.
public struct PrivacyConsentView: View {
    @Bindable private var viewModel: PrivacyConsentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailsSheetPresented: Bool = false

    public init(viewModel: PrivacyConsentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    toggles
                    privacyFootnote
                    continueButton
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 520)
            }
        }
        .accessibilityID(.consentRoot)
        .catlaserDynamicTypeBounds()
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: viewModel.isCommitting,
        )
        .sheet(isPresented: $detailsSheetPresented) {
            PrivacyDetailsSheet(onDismiss: { detailsSheetPresented = false })
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityDecorativeIcon()
            Text(PrivacyConsentStrings.title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(PrivacyConsentStrings.subtitle)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(SemanticColor.textSecondary)
        }
    }

    private var toggles: some View {
        VStack(spacing: 16) {
            consentToggle(
                isOn: $viewModel.crashReportingEnabled,
                title: PrivacyConsentStrings.crashToggleTitle,
                body: PrivacyConsentStrings.crashToggleBody,
                id: .consentCrashToggle,
            )
            consentToggle(
                isOn: $viewModel.telemetryEnabled,
                title: PrivacyConsentStrings.telemetryToggleTitle,
                body: PrivacyConsentStrings.telemetryToggleBody,
                id: .consentTelemetryToggle,
            )
        }
    }

    private func consentToggle(
        isOn: Binding<Bool>,
        title: String,
        body: String,
        id: AccessibilityID,
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(SemanticColor.textPrimary)
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            SemanticColor.groupedBackground,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SemanticColor.separator, lineWidth: 1),
        )
        .accessibilityID(id)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(body))
    }

    private var privacyFootnote: some View {
        // Hero sentence + info icon. The hero is deliberately plain-
        // language (no "TLS-pinned, device-hashed, stripped of personal
        // identifiers" jargon); the specifics live behind the info tap
        // for users who want to audit the claim. The (ⓘ) tap target is
        // inline with the text so a VoiceOver user lands on it while
        // reading the sentence rather than having to hunt for a
        // separate element.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(PrivacyConsentStrings.privacyNote)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(SemanticColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                detailsSheetPresented = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.callout)
                    .foregroundStyle(SemanticColor.accent)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityID(.consentPrivacyInfo)
            .accessibilityLabel(Text(PrivacyConsentStrings.privacyInfoAccessibilityLabel))
        }
        .padding(.horizontal, 8)
    }

    private var continueButton: some View {
        Button {
            Haptics.commit.play()
            Task { await viewModel.commit() }
        } label: {
            ZStack {
                Text(PrivacyConsentStrings.continueButton)
                    .font(.body.weight(.semibold))
                    .opacity(viewModel.isCommitting ? 0 : 1)
                if viewModel.isCommitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .accessibilityLabel(Text(PrivacyConsentStrings.continueButton))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(SemanticColor.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isCommitting)
        .accessibilityID(.consentContinue)
        .accessibilityLabel(Text(PrivacyConsentStrings.continueButton))
    }
}

/// Details sheet presented on a tap of the info icon next to the
/// privacy hero. Keeps the hero copy mom-friendly while giving
/// audit-minded users a drill-in with the concrete claims: TLS
/// pinning, home-network-only video, no third-party trackers,
/// minimal data collection.
private struct PrivacyDetailsSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(PrivacyConsentStrings.privacyDetailsBody)
                        .font(.body)
                        .foregroundStyle(SemanticColor.textPrimary)
                    bullet(
                        iconName: "lock.shield",
                        title: PrivacyConsentStrings.privacyDetailsTlsTitle,
                        body: PrivacyConsentStrings.privacyDetailsTlsBody,
                    )
                    bullet(
                        iconName: "house",
                        title: PrivacyConsentStrings.privacyDetailsLocalTitle,
                        body: PrivacyConsentStrings.privacyDetailsLocalBody,
                    )
                    bullet(
                        iconName: "nosign",
                        title: PrivacyConsentStrings.privacyDetailsNoTrackersTitle,
                        body: PrivacyConsentStrings.privacyDetailsNoTrackersBody,
                    )
                    bullet(
                        iconName: "sparkles",
                        title: PrivacyConsentStrings.privacyDetailsMinimalTitle,
                        body: PrivacyConsentStrings.privacyDetailsMinimalBody,
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .navigationTitle(PrivacyConsentStrings.privacyDetailsTitle)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .confirmationAction) {
                        Button(PrivacyConsentStrings.privacyDetailsDone, action: onDismiss)
                    }
                    #else
                    ToolbarItem {
                        Button(PrivacyConsentStrings.privacyDetailsDone, action: onDismiss)
                    }
                    #endif
                }
        }
    }

    private func bullet(iconName: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(SemanticColor.accent)
                .frame(width: 28)
                .accessibilityDecorativeIcon()
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(SemanticColor.textPrimary)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
