#if canImport(SwiftUI)
import CatLaserDesign
import Foundation
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// SwiftUI screen that primes the user for push authorization and
/// surfaces the registration state.
///
/// Every control on screen binds to a ``PushViewModel`` method or
/// observable property — the view holds no local state of its own.
/// Tests therefore exercise the VM directly and this view is a thin
/// presentation layer whose correctness is "control wired to VM
/// action and VM property wired to control state."
public struct PushView: View {
    @Bindable private var viewModel: PushViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var errorFocus: Bool

    public init(viewModel: PushViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            content
                .padding(.horizontal, 24)
        }
        .accessibilityID(.pushRoot)
        .catlaserDynamicTypeBounds()
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: stateTag,
        )
        .onChange(of: stateTag) { _, newValue in
            switch newValue {
            case "failed":
                errorFocus = true
                Haptics.error.play()
            case "authorizationDenied":
                // Not an error — the user's explicit choice. But it
                // is the terminal state of their tap on "Turn on",
                // so a warning haptic underlines the denial without
                // treating it as failure.
                Haptics.warning.play()
            case "registered":
                Haptics.success.play()
            default:
                break
            }
        }
        .task {
            await viewModel.start()
        }
    }

    private var stateTag: String {
        switch viewModel.state {
        case .idle: "idle"
        case .requestingAuthorization: "requestingAuthorization"
        case .awaitingAPNsToken: "awaitingAPNsToken"
        case .registering: "registering"
        case .registered: "registered"
        case .authorizationDenied: "authorizationDenied"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            primer
        case .requestingAuthorization, .awaitingAPNsToken:
            progress(label: PushStrings.awaitingTokenLabel)
        case .registering:
            progress(label: PushStrings.registeringLabel)
        case .registered:
            success
        case .authorizationDenied:
            denied
        case let .failed(error):
            failure(error: error)
        }
    }

    // MARK: - State panes

    private var primer: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityDecorativeIcon()
            Text(PushStrings.primerTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityHeader()
            Text(PushStrings.primerBody)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(PushStrings.primerAllowButton) {
                Haptics.commit.play()
                Task { await viewModel.requestAuthorization() }
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(SemanticColor.accent, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityID(.pushPrimerAllow)
            .accessibilityLabel(Text(PushStrings.primerAllowButton))
        }
    }

    private func progress(label: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
                .accessibilityLabel(Text(label))
            Text(label)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var success: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(SemanticColor.success)
                .accessibilityDecorativeIcon()
            Text(PushStrings.registeredTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityHeader()
            Text(PushStrings.registeredBody)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var denied: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.slash")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(SemanticColor.warning)
                .accessibilityDecorativeIcon()
            Text(PushStrings.deniedTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityHeader()
            Text(PushStrings.deniedBody)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(PushStrings.openSettingsButton, action: openSettings)
                .buttonStyle(.plain)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(SemanticColor.accent, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityID(.pushOpenSettings)
                .accessibilityLabel(Text(PushStrings.openSettingsButton))
        }
    }

    private func failure(error: PushError) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(SemanticColor.warning)
                .accessibilityDecorativeIcon()
            Text(PushStrings.errorBannerTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(PushStrings.message(for: error))
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityFocused($errorFocus)
            Spacer()
            Button(PushStrings.retryButton) {
                Haptics.commit.play()
                Task { await viewModel.retry() }
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(SemanticColor.accent, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityID(.pushRetry)
            .accessibilityLabel(Text(PushStrings.retryButton))
        }
    }

    // MARK: - iOS Settings deep link

    private func openSettings() {
        #if canImport(UIKit) && !os(watchOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
#endif
