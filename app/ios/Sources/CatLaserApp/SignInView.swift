#if canImport(SwiftUI)
import CatLaserAuth
import CatLaserDesign
import Foundation
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Root sign-in screen. Renders three mutually-exclusive authentication
/// paths (Apple, Google, magic link) and an error banner. Attaches
/// `.onOpenURL` at the root so Universal Link callbacks route into the
/// VM regardless of which surface inside the screen is foreground.
///
/// This view owns no state itself — every visible string, every enabled/
/// disabled flag, and every transition is driven by `SignInViewModel`.
/// Tests therefore exercise the VM directly and this view is a thin
/// presentation layer whose correctness is "button wired to VM method
/// and VM property wired to control property."
public struct SignInView: View {
    @Bindable private var viewModel: SignInViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var errorFocus: Bool

    public init(viewModel: SignInViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            mainContent
                .opacity(isCoverPaneVisible ? 0 : 1)
                // The cover pane blocks taps on the buttons behind it.
                // Without this, a user who tapped a Universal Link
                // while the app was running could still send a second
                // Apple/Google tap before the verification returned —
                // a legitimate but accidental double-commit.
                .allowsHitTesting(!isCoverPaneVisible)

            if let address = emailSentAddress {
                EmailSentView(
                    viewModel: viewModel,
                    address: address,
                    isResending: isResendingMagicLink,
                    onResend: {
                        Haptics.light.play()
                        Task { await viewModel.resendMagicLink() }
                    },
                    onUseDifferentEmail: { viewModel.useDifferentEmail() },
                )
                .transition(.opacity)
            } else if isVerifyingMagicLink {
                VerifyingMagicLinkView()
                    .transition(.opacity)
            }
        }
        .accessibilityID(.signInRoot)
        .catlaserDynamicTypeBounds()
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: coverPaneTag,
        )
        .sheet(isPresented: $viewModel.emailSheetPresented) {
            EmailEntrySheet(viewModel: viewModel)
        }
        .onOpenURL { url in
            Task { await viewModel.completeMagicLink(url: url) }
        }
        .task {
            await viewModel.resume()
        }
        .onChange(of: viewModel.currentErrorMessage) { _, newValue in
            if newValue != nil {
                errorFocus = true
                Haptics.error.play()
            }
        }
    }

    /// Address to render on the "check your email" screen while we are
    /// in `.emailSent` or mid-resend. Nil when the main sign-in
    /// content should be showing.
    private var emailSentAddress: String? {
        switch viewModel.phase {
        case let .emailSent(address), let .resendingMagicLink(address): address
        default: nil
        }
    }

    private var isResendingMagicLink: Bool {
        if case .resendingMagicLink = viewModel.phase { true } else { false }
    }

    /// True while the VM is verifying a Universal-Link-tapped magic
    /// link. Covers both the in-session case (transition from
    /// ``.emailSent`` → ``.verifyingMagicLink``) AND the cold-start
    /// case (app launches off a tapped link; VM starts in ``.idle``
    /// and ``completeMagicLink(url:)`` flips the phase before the
    /// main content would otherwise render the sign-in buttons).
    private var isVerifyingMagicLink: Bool {
        if case .verifyingMagicLink = viewModel.phase { true } else { false }
    }

    /// Whether a full-screen cover pane is drawn on top of
    /// ``mainContent``. Used to both hide the buttons and disable
    /// their hit-testing so an in-flight verification cannot be
    /// raced by a stray social-button tap.
    private var isCoverPaneVisible: Bool {
        emailSentAddress != nil || isVerifyingMagicLink
    }

    /// Stable tag for the cover-pane animation. Distinguishes
    /// "email sent for address X" from "verifying" from "main
    /// content" so SwiftUI cross-fades cleanly across transitions.
    private var coverPaneTag: String {
        if let emailSentAddress {
            return "emailSent:\(emailSentAddress)"
        }
        if isVerifyingMagicLink {
            return "verifying"
        }
        return "main"
    }

    private var mainContent: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)

            header

            Spacer()

            VStack(spacing: 12) {
                AppleSignInButton(
                    isActive: viewModel.phase == .authenticating(.apple),
                    isEnabled: !viewModel.phase.isBusy,
                    action: {
                        Haptics.commit.play()
                        Task { await viewModel.signInWithApple(context: currentPresentationContext()) }
                    },
                )

                GoogleSignInButton(
                    isActive: viewModel.phase == .authenticating(.google),
                    isEnabled: !viewModel.phase.isBusy,
                    action: {
                        Haptics.commit.play()
                        Task { await viewModel.signInWithGoogle(context: currentPresentationContext()) }
                    },
                )

                DividerLabel(text: SignInStrings.dividerLabel)
                    .padding(.vertical, 4)

                EmailEntryButton(
                    isEnabled: !viewModel.phase.isBusy,
                    action: { viewModel.presentEmailSheet() },
                )
            }
            .frame(maxWidth: 420)

            Spacer()

            if let message = viewModel.currentErrorMessage {
                ErrorBanner(
                    title: SignInStrings.errorBannerTitle,
                    message: message,
                    dismissLabel: SignInStrings.dismissButton,
                    onDismiss: { viewModel.dismissError() },
                )
                .accessibilityFocused($errorFocus)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: viewModel.currentErrorMessage,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityDecorativeIcon()
            Text(SignInStrings.title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(SignInStrings.subtitle)
                .font(.body)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Build a `ProviderPresentationContext`. The value is nil-initialised
    /// on both platforms; the provider falls back to the key window /
    /// active scene, which is what we want — SwiftUI has no public way
    /// to hand out a UIViewController without a `UIViewControllerRepresentable`
    /// detour, and the fallback does the right thing across split view,
    /// multi-scene, and sheet contexts.
    private func currentPresentationContext() -> ProviderPresentationContext {
        #if canImport(UIKit) && !os(watchOS)
        return ProviderPresentationContext(viewController: nil)
        #elseif canImport(AppKit)
        return ProviderPresentationContext(window: nil)
        #else
        return ProviderPresentationContext()
        #endif
    }
}

// MARK: - Subviews

private struct AppleSignInButton: View {
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "applelogo")
                        .font(.body.weight(.medium))
                        .accessibilityHidden(true)
                    Text(SignInStrings.appleButton)
                        .font(.body.weight(.semibold))
                }
                .opacity(isActive ? 0 : 1)

                if isActive {
                    ProgressView()
                        .tint(SemanticColor.appleButtonForeground)
                        .accessibilityLabel(Text(SignInStrings.appleButton))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(SemanticColor.appleButtonBackground)
            .foregroundStyle(SemanticColor.appleButtonForeground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityID(.signInAppleButton)
        .accessibilityLabel(Text(SignInStrings.appleButton))
    }
}

private struct GoogleSignInButton: View {
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill")
                        .font(.body.weight(.medium))
                        .accessibilityHidden(true)
                    Text(SignInStrings.googleButton)
                        .font(.body.weight(.semibold))
                }
                .opacity(isActive ? 0 : 1)

                if isActive {
                    ProgressView()
                        .accessibilityLabel(Text(SignInStrings.googleButton))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(SemanticColor.googleButtonBackground)
            .foregroundStyle(SemanticColor.googleButtonForeground)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SemanticColor.separator, lineWidth: 1),
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityID(.signInGoogleButton)
        .accessibilityLabel(Text(SignInStrings.googleButton))
    }
}

private struct EmailEntryButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .font(.body.weight(.medium))
                    .accessibilityHidden(true)
                Text(SignInStrings.emailButton)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(SemanticColor.accent)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SemanticColor.accent, lineWidth: 1),
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityID(.signInEmailButton)
        .accessibilityLabel(Text(SignInStrings.emailButton))
    }
}

private struct DividerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(SemanticColor.separator)
                .frame(height: 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(SemanticColor.textSecondary)
                .accessibilityHidden(true)
            Rectangle()
                .fill(SemanticColor.separator)
                .frame(height: 1)
        }
    }
}

private struct EmailEntrySheet: View {
    @Bindable var viewModel: SignInViewModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(SignInStrings.emailSheetTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                    .accessibilityHeader()
                // Pre-send: value statement, not post-send expiry
                // warning. The "link expires" copy is post-send
                // context and lives on ``EmailSentView``.
                Text(SignInStrings.emailSheetPrompt)
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textSecondary)

                TextField(
                    SignInStrings.emailFieldPlaceholder,
                    text: $viewModel.emailInput,
                )
                #if canImport(UIKit) && !os(watchOS)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .autocorrectionDisabled(true)
                #endif
                .submitLabel(.send)
                .onSubmit {
                    // The keyboard's return key is the obvious commit
                    // gesture for a single-field form; without
                    // ``onSubmit`` it would do nothing and the user
                    // would have to reach for the button. The same
                    // VM-side validity gate the button uses applies
                    // here so an invalid address does not silently
                    // fire a network call.
                    guard viewModel.canRequestMagicLink else { return }
                    Haptics.commit.play()
                    Task { await viewModel.requestMagicLink() }
                }
                .textFieldStyle(.roundedBorder)
                .accessibilityID(.signInEmailField)
                .accessibilityLabel(Text(SignInStrings.emailFieldLabel))

                if !viewModel.emailInput.isEmpty, !viewModel.isEmailInputValid {
                    Text(SignInStrings.emailInvalid)
                        .font(.footnote)
                        .foregroundStyle(SemanticColor.destructive)
                }

                Button {
                    Haptics.commit.play()
                    Task { await viewModel.requestMagicLink() }
                } label: {
                    ZStack {
                        Text(viewModel.phase == .requestingMagicLink
                            ? SignInStrings.emailSendingButton
                            : SignInStrings.emailSendButton)
                            .font(.body.weight(.semibold))
                            .opacity(viewModel.phase == .requestingMagicLink ? 0.6 : 1)
                        if viewModel.phase == .requestingMagicLink {
                            ProgressView()
                                .tint(.white)
                                .accessibilityLabel(Text(SignInStrings.emailSendingButton))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        viewModel.canRequestMagicLink
                            ? SemanticColor.accent
                            : SemanticColor.textTertiary,
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRequestMagicLink)
                .accessibilityID(.signInEmailSubmit)
                .accessibilityLabel(Text(SignInStrings.emailSendButton))

                if let message = viewModel.currentErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(SemanticColor.destructive)
                        .accessibilityAddTraits(.isStaticText)
                }

                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SignInStrings.cancelButton) {
                        viewModel.dismissEmailSheet()
                    }
                    .accessibilityID(.signInEmailCancel)
                }
            }
        }
    }
}

private struct EmailSentView: View {
    @Bindable var viewModel: SignInViewModel
    let address: String
    let isResending: Bool
    let onResend: () -> Void
    let onUseDifferentEmail: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                backupCodeSection
                resendFooter
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityDecorativeIcon()

            VStack(spacing: 8) {
                Text(SignInStrings.emailSentTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                    .accessibilityHeader()
                Text(SignInStrings.emailSentBody(address))
                    .font(.body)
                    .foregroundStyle(SemanticColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(SignInStrings.emailSentHint)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var backupCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SignInStrings.backupCodePrompt)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
            Text(SignInStrings.backupCodeHint)
                .font(.footnote)
                .foregroundStyle(SemanticColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(SignInStrings.backupCodePlaceholder, text: $viewModel.backupCodeInput)
                #if canImport(UIKit) && !os(watchOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocapitalization(.none)
                .autocorrectionDisabled(true)
                #endif
                .font(.title3.monospacedDigit())
                .submitLabel(.go)
                .onSubmit {
                    guard viewModel.canSubmitBackupCode else { return }
                    Haptics.commit.play()
                    Task { await viewModel.submitBackupCode() }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SemanticColor.groupedBackground),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SemanticColor.separator, lineWidth: 1),
                )
                .accessibilityID(.signInBackupCodeField)
                .accessibilityLabel(Text(SignInStrings.backupCodeFieldLabel))

            if !viewModel.backupCodeInput.isEmpty, !viewModel.isBackupCodeInputValid {
                Text(SignInStrings.backupCodeInvalid)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.destructive)
            }

            Button {
                Haptics.commit.play()
                Task { await viewModel.submitBackupCode() }
            } label: {
                Text(SignInStrings.backupCodeSubmitButton)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        viewModel.canSubmitBackupCode
                            ? SemanticColor.accent
                            : SemanticColor.textTertiary,
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmitBackupCode)
            .accessibilityID(.signInBackupCodeSubmit)
            .accessibilityLabel(Text(SignInStrings.backupCodeSubmitButton))
        }
    }

    private var resendFooter: some View {
        VStack(spacing: 12) {
            Button(action: onResend) {
                ZStack {
                    Text(SignInStrings.resendButton)
                        .font(.body.weight(.semibold))
                        .opacity(isResending ? 0 : 1)
                    if isResending {
                        ProgressView()
                            .accessibilityLabel(Text(SignInStrings.resendButton))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isResending)
            .accessibilityID(.signInEmailSentResend)
            .accessibilityLabel(Text(SignInStrings.resendButton))

            Button(action: onUseDifferentEmail) {
                Text(SignInStrings.useDifferentEmailButton)
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SemanticColor.textSecondary)
            .disabled(isResending)
            .accessibilityID(.signInEmailSentUseDifferent)
            .accessibilityLabel(Text(SignInStrings.useDifferentEmailButton))
        }
    }
}

/// Cover pane rendered while the VM is verifying a tapped Universal
/// Link. Runs over the main sign-in content so a user who tapped the
/// email link and returned to the app sees progress instead of the
/// sign-in buttons apparently still inviting a tap.
private struct VerifyingMagicLinkView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .scaleEffect(1.4)
                .tint(SemanticColor.accent)
                .accessibilityLabel(Text(SignInStrings.verifyingMagicLinkTitle))
                .accessibilityAddTraits(.updatesFrequently)

            VStack(spacing: 8) {
                Text(SignInStrings.verifyingMagicLinkTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityHeader()
                Text(SignInStrings.verifyingMagicLinkSubtitle)
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Combine the spinner + title into one accessibility element
        // so VoiceOver reads the state once per focus rather than
        // three times (spinner / title / subtitle).
        .accessibilityElement(children: .combine)
    }
}

private struct ErrorBanner: View {
    let title: String
    let message: String
    let dismissLabel: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(SemanticColor.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Text(dismissLabel)
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SemanticColor.accent)
            .accessibilityID(.signInErrorDismiss)
            .accessibilityLabel(Text(dismissLabel))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SemanticColor.groupedBackground),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SemanticColor.separator, lineWidth: 1),
        )
        .frame(maxWidth: 520)
        .accessibilityID(.signInErrorBanner)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(message)"))
    }
}
#endif
