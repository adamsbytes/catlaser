#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// Live-view screen.
///
/// Four visual states, one per non-busy `LiveViewState` case, plus a
/// shared spinner overlay for the three busy cases. Every control on
/// screen is bound to a VM property — the view has no state of its
/// own, so tests exercise the VM directly (matching `SignInView`).
///
/// Video rendering is delegated to `LiveVideoView`, a
/// `UIViewRepresentable` (or `NSViewRepresentable`) that wraps
/// LiveKit's `VideoView`. When `LiveKit` is not linked the delegate
/// falls back to a placeholder, so the screen still compiles and runs
/// with a mock session.
public struct LiveView: View {
    @Bindable private var viewModel: LiveViewModel

    public init(viewModel: LiveViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            backgroundView
            contentView
        }
        .animation(.easeInOut(duration: 0.2), value: stateTag)
        .task {
            // If the view goes away mid-connect (user navigates out),
            // cancel the stream to tear down the device-side and
            // LiveKit-side resources cleanly.
            await withTaskCancellationHandler {
                // No-op body; the handler fires on cancel.
                for await _ in AsyncStream<Void> { continuation in
                    continuation.onTermination = { _ in continuation.finish() }
                } {}
            } onCancel: {
                Task { @MainActor in
                    if viewModel.state.canStop {
                        await viewModel.stop()
                    }
                }
            }
        }
    }

    private var stateTag: String {
        switch viewModel.state {
        case .disconnected: "disconnected"
        case .requestingOffer: "requestingOffer"
        case .connecting: "connecting"
        case .streaming: "streaming"
        case .disconnecting: "disconnecting"
        case .failed: "failed"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .disconnected:
            disconnectedContent
        case .requestingOffer, .connecting:
            loadingContent
        case let .streaming(track):
            streamingContent(track: track)
        case .disconnecting:
            disconnectingContent
        case let .failed(error):
            failedContent(error: error)
        }
    }

    private var backgroundView: some View {
        Color.black.ignoresSafeArea()
    }

    private var disconnectedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
            Text(LiveViewStrings.disconnectedTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(LiveViewStrings.disconnectedSubtitle)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Task { await viewModel.start() }
            } label: {
                Text(LiveViewStrings.watchLiveButton)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LiveViewStrings.watchLiveButton))
        }
        .frame(maxWidth: 420)
        .padding()
    }

    private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.white)
            Text(loadingLabel)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var loadingLabel: String {
        switch viewModel.state {
        case .requestingOffer: LiveViewStrings.requestingOfferLabel
        case .connecting: LiveViewStrings.connectingLabel
        default: LiveViewStrings.connectingLabel
        }
    }

    @ViewBuilder
    private func streamingContent(track: any LiveVideoTrackHandle) -> some View {
        ZStack(alignment: .bottom) {
            LiveVideoView(track: track)
                .ignoresSafeArea()
                .accessibilityLabel(Text(LiveViewStrings.videoAccessibilityLabel))

            HStack {
                Spacer()
                Button {
                    Task { await viewModel.stop() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.circle.fill")
                        Text(LiveViewStrings.stopButton)
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LiveViewStrings.stopButton))
                Spacer()
            }
            .padding(.bottom, 32)
        }
    }

    private var disconnectingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)
            Text(LiveViewStrings.disconnectingLabel)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func failedContent(error: LiveViewError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(LiveViewStrings.failedTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(LiveViewStrings.message(for: error))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button {
                    viewModel.dismissError()
                } label: {
                    Text(LiveViewStrings.dismissButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button {
                    Task {
                        viewModel.dismissError()
                        await viewModel.start()
                    }
                } label: {
                    Text(LiveViewStrings.retryButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }
}
#endif
