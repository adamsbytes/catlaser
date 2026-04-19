#if canImport(SwiftUI)
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

    public init(viewModel: PushViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
                .padding(.horizontal, 24)
        }
        .task {
            await viewModel.start()
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
                .foregroundStyle(.white.opacity(0.9))
                .accessibilityHidden(true)
            Text(PushStrings.primerTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(PushStrings.primerBody)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
            Button(PushStrings.primerAllowButton) {
                Task { await viewModel.requestAuthorization() }
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel(Text(PushStrings.primerAllowButton))
        }
    }

    private func progress(label: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
                .tint(.white)
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var success: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(PushStrings.registeredTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(PushStrings.registeredBody)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var denied: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.slash")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(PushStrings.deniedTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(PushStrings.deniedBody)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
            Button(PushStrings.openSettingsButton, action: openSettings)
                .buttonStyle(.plain)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private func failure(error: PushError) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(PushStrings.errorBannerTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(PushStrings.message(for: error))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
            Button(PushStrings.retryButton) {
                Task { await viewModel.retry() }
            }
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
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
