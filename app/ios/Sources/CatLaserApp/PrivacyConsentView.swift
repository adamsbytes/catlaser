#if canImport(SwiftUI)
import CatLaserDesign
import SwiftUI

/// First-launch consent screen.
///
/// Presented once (on first install, and again if ``ConsentStore``'s
/// versioned key has been rotated). Two toggles, a privacy footnote,
/// and a Continue button. Defaults are both ON — the toggles are
/// labelled explicitly and the user must scroll past the consent
/// copy before tapping Continue, which matches Apple's definition of
/// opt-in without burying the choice.
public struct PrivacyConsentView: View {
    @Bindable private var viewModel: PrivacyConsentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        Text(PrivacyConsentStrings.privacyNote)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(SemanticColor.textSecondary)
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
#endif
