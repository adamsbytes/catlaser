#if canImport(SwiftUI)
import CatLaserAuth
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

    public init(viewModel: SignInViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            mainContent
                .opacity(emailSentAddress == nil ? 1 : 0)

            if let address = emailSentAddress {
                EmailSentView(
                    address: address,
                    isResending: isResendingMagicLink,
                    onResend: { Task { await viewModel.resendMagicLink() } },
                    onUseDifferentEmail: { viewModel.useDifferentEmail() },
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: emailSentAddress)
        .sheet(isPresented: $viewModel.emailSheetPresented) {
            EmailEntrySheet(viewModel: viewModel)
        }
        .onOpenURL { url in
            Task { await viewModel.completeMagicLink(url: url) }
        }
        .task {
            await viewModel.resume()
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

    private var mainContent: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)

            header

            Spacer()

            VStack(spacing: 12) {
                AppleSignInButton(
                    isActive: viewModel.phase == .authenticating(.apple),
                    isEnabled: !viewModel.phase.isBusy,
                    action: { Task { await viewModel.signInWithApple(context: currentPresentationContext()) } },
                )

                GoogleSignInButton(
                    isActive: viewModel.phase == .authenticating(.google),
                    isEnabled: !viewModel.phase.isBusy,
                    action: { Task { await viewModel.signInWithGoogle(context: currentPresentationContext()) } },
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
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .animation(.easeInOut(duration: 0.2), value: viewModel.currentErrorMessage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(SignInStrings.title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(SignInStrings.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
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
                    Text(SignInStrings.appleButton)
                        .font(.body.weight(.semibold))
                }
                .opacity(isActive ? 0 : 1)

                if isActive {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.black)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
                    Text(SignInStrings.googleButton)
                        .font(.body.weight(.semibold))
                }
                .opacity(isActive ? 0 : 1)

                if isActive {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(white: 0.98))
            .foregroundStyle(.black)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(white: 0.85), lineWidth: 1),
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
                Text(SignInStrings.emailButton)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(Color.accentColor)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 1),
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(SignInStrings.emailButton))
    }
}

private struct DividerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color(white: 0.85))
                .frame(height: 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Rectangle()
                .fill(Color(white: 0.85))
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
                Text(SignInStrings.emailSentHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)

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
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text(SignInStrings.emailFieldLabel))

                if !viewModel.emailInput.isEmpty, !viewModel.isEmailInputValid {
                    Text(SignInStrings.emailInvalid)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
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
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(viewModel.canRequestMagicLink ? Color.accentColor : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRequestMagicLink)

                if let message = viewModel.currentErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
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
                }
            }
        }
    }
}

private struct EmailSentView: View {
    let address: String
    let isResending: Bool
    let onResend: () -> Void
    let onUseDifferentEmail: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "envelope.badge")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(SignInStrings.emailSentTitle)
                    .font(.title2.weight(.semibold))
                Text(SignInStrings.emailSentBody(address))
                    .font(.body)
                    .multilineTextAlignment(.center)
                Text(SignInStrings.emailSentHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: onResend) {
                    ZStack {
                        Text(SignInStrings.resendButton)
                            .font(.body.weight(.semibold))
                            .opacity(isResending ? 0 : 1)
                        if isResending {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isResending)

                Button(action: onUseDifferentEmail) {
                    Text(SignInStrings.useDifferentEmailButton)
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isResending)
            }
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Text(dismissLabel)
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(Text(dismissLabel))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.96)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(white: 0.85), lineWidth: 1),
        )
        .frame(maxWidth: 520)
    }
}
#endif
