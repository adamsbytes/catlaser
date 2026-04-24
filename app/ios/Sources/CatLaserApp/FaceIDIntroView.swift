#if canImport(SwiftUI)
import CatLaserDesign
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Face ID / passcode onboarding card. Shown ONCE per install,
/// between the privacy-consent screen and the sign-in flow.
///
/// Two copy variants driven by ``FaceIDIntroViewModel/biometricsAvailable``:
///
/// * `true`  — the user already has Face ID / Touch ID / a passcode set
///   up. Copy frames the gate as a feature ("Only you can watch your
///   home"); a single Got it button commits the flag and advances the
///   shell.
/// * `false` — no biometric / passcode is enrolled. The app's live-
///   video surface hard-depends on user-presence, so we warn explicitly
///   and prefer the user sets one up in Settings. Two buttons: "Open
///   Settings" (primary, opens the OS preferences) and "Continue
///   anyway" (secondary, still commits the flag). Both paths flip the
///   flag — the card is a one-shot onboarding moment, not a gate.
public struct FaceIDIntroView: View {
    @Bindable private var viewModel: FaceIDIntroViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: FaceIDIntroViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    bodyText
                    if !viewModel.biometricsAvailable {
                        warningCallout
                    }
                    Spacer(minLength: 16)
                    actionButtons
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 520)
            }
        }
        .accessibilityID(.faceIDIntroRoot)
        .catlaserDynamicTypeBounds()
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: viewModel.isCommitting,
        )
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityDecorativeIcon()
            Text(FaceIDIntroStrings.title(biometricsAvailable: viewModel.biometricsAvailable))
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
        }
    }

    private var iconName: String {
        viewModel.biometricsAvailable ? "faceid" : "lock.shield"
    }

    private var bodyText: some View {
        Text(FaceIDIntroStrings.body(biometricsAvailable: viewModel.biometricsAvailable))
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(SemanticColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var warningCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SemanticColor.warning)
                    .accessibilityHidden(true)
                Text(FaceIDIntroStrings.warningTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
            }
            Text(FaceIDIntroStrings.warningBody)
                .font(.footnote)
                .foregroundStyle(SemanticColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionButtons: some View {
        if viewModel.biometricsAvailable {
            primaryButton(
                title: FaceIDIntroStrings.continueButton,
                id: .faceIDIntroContinue,
                action: { await viewModel.commit() },
            )
        } else {
            VStack(spacing: 10) {
                primaryButton(
                    title: FaceIDIntroStrings.openSettingsButton,
                    id: .faceIDIntroOpenSettings,
                    action: {
                        #if canImport(UIKit) && os(iOS)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            await UIApplication.shared.open(url)
                        }
                        #endif
                    },
                )
                secondaryButton(
                    title: FaceIDIntroStrings.continueAnywayButton,
                    id: .faceIDIntroContinue,
                    action: { await viewModel.commit() },
                )
            }
        }
    }

    private func primaryButton(
        title: String,
        id: AccessibilityID,
        action: @MainActor @escaping () async -> Void,
    ) -> some View {
        Button {
            Haptics.commit.play()
            Task { await action() }
        } label: {
            ZStack {
                Text(title)
                    .font(.body.weight(.semibold))
                    .opacity(viewModel.isCommitting ? 0 : 1)
                if viewModel.isCommitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .accessibilityLabel(Text(title))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(SemanticColor.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isCommitting)
        .accessibilityID(id)
        .accessibilityLabel(Text(title))
    }

    private func secondaryButton(
        title: String,
        id: AccessibilityID,
        action: @MainActor @escaping () async -> Void,
    ) -> some View {
        Button {
            Haptics.light.play()
            Task { await action() }
        } label: {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(SemanticColor.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isCommitting)
        .accessibilityID(id)
        .accessibilityLabel(Text(title))
    }
}

enum FaceIDIntroStrings {
    static func title(biometricsAvailable: Bool) -> String {
        if biometricsAvailable {
            return NSLocalizedString(
                "onboarding.faceid.title.available",
                value: "Only you can watch your home",
                comment: "Title on the Face ID intro card when biometrics or a passcode is set up.",
            )
        }
        return NSLocalizedString(
            "onboarding.faceid.title.unavailable",
            value: "Lock your iPhone first",
            comment: "Title on the Face ID intro card when neither biometrics nor a passcode is set up.",
        )
    }

    static func body(biometricsAvailable: Bool) -> String {
        if biometricsAvailable {
            return NSLocalizedString(
                "onboarding.faceid.body.available",
                value: "Face ID or your passcode is required every time you watch the live feed. We never want anyone — including us — seeing inside your home without your consent.",
                comment: "Body copy on the Face ID intro card when biometrics or a passcode is set up.",
            )
        }
        return NSLocalizedString(
            "onboarding.faceid.body.unavailable",
            value: "Without Face ID or a passcode, anyone holding your phone could watch inside your home through the live feed. We strongly recommend adding one in Settings before using Catlaser.",
            comment: "Body copy on the Face ID intro card when neither biometrics nor a passcode is set up.",
        )
    }

    static let warningTitle = NSLocalizedString(
        "onboarding.faceid.warning.title",
        value: "Your phone isn't locked",
        comment: "Warning heading on the Face ID intro card when nothing is enrolled.",
    )

    static let warningBody = NSLocalizedString(
        "onboarding.faceid.warning.body",
        value: "Anyone with physical access to this phone could watch your camera feed. Add Face ID or a passcode in Settings > Face ID & Passcode.",
        comment: "Warning body on the Face ID intro card when nothing is enrolled.",
    )

    static let continueButton = NSLocalizedString(
        "onboarding.faceid.continue",
        value: "Got it",
        comment: "Primary button that advances past the Face ID intro card.",
    )

    static let openSettingsButton = NSLocalizedString(
        "onboarding.faceid.open_settings",
        value: "Open Settings",
        comment: "Primary button shown when biometrics are unavailable — opens iOS Settings.",
    )

    static let continueAnywayButton = NSLocalizedString(
        "onboarding.faceid.continue_anyway",
        value: "Continue anyway",
        comment: "Secondary button shown when biometrics are unavailable — advances past the card without setting up.",
    )
}
#endif
