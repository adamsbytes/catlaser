#if canImport(SwiftUI)
import CatLaserDesign
import CatLaserProto
import Foundation
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Live-view screen.
///
/// Four visual states, one per non-busy `LiveViewState` case, plus a
/// shared spinner overlay for the three busy cases. Every control on
/// screen is bound to a VM property — the view has no state of its
/// own beyond the transient control-visibility timer, so tests
/// exercise the VM directly (matching `SignInView`).
///
/// Video rendering is delegated to `LiveVideoView`, a
/// `UIViewRepresentable` (or `NSViewRepresentable`) that wraps
/// LiveKit's `VideoView`. When `LiveKit` is not linked the delegate
/// falls back to a placeholder, so the screen still compiles and runs
/// with a mock session.
///
/// ## Streaming UX
///
/// While streaming, the screen displays:
///
/// 1. The live video feed, full-bleed against a black canvas.
/// 2. A top session-status pill ("Playing now · 1m 20s") that
///    updates every second via a `TimelineView` and renders a
///    hopper-low / hopper-empty badge next to it when the device
///    reports a low level.
/// 3. A bottom Stop button that tears the stream down.
///
/// Tap the video area once to toggle the overlay chrome visibility;
/// after three seconds of idle it auto-hides so the feed is
/// unobstructed. VoiceOver users see the chrome at all times — the
/// auto-hide is suppressed when
/// ``accessibilityVoiceOverEnabled`` is true because the gesture
/// needed to reveal the controls is not discoverable under VoiceOver.
public struct LiveView: View {
    @Bindable private var viewModel: LiveViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var errorFocus: Bool

    /// Visibility of the streaming overlay chrome (top status pill +
    /// bottom Stop button). Toggled by a tap on the video and auto-
    /// reset by an inactivity timer. Initialised `true` so a user
    /// landing on a fresh stream sees the controls immediately; the
    /// auto-hide timer takes over three seconds later.
    @State private var controlsVisible: Bool = true

    /// Countdown Task that flips ``controlsVisible`` back to `false`.
    /// Re-armed on every tap so the idle timer restarts with each
    /// interaction; cancelled on tap-to-hide and on view disappear.
    @State private var controlsHideTask: Task<Void, Never>?

    /// Last-rendered frame from the previous streaming session.
    /// Captured by ``LiveVideoView`` on dismantle and rendered as a
    /// blurred backdrop on ``disconnectedContent`` so the user sees
    /// where the feed left off instead of a blank slate while
    /// re-dialling. Scoped to the ``LiveView`` instance — switching
    /// tabs preserves it (TabView keeps subviews alive), but a full
    /// shell rebuild (sign-out, re-pair) tears the ``LiveView`` down
    /// along with the poster. Kept in ``@State`` rather than on the
    /// VM because the capture type (``UIImage``) is UIKit-only and
    /// the VM is cross-platform; the image never leaves the view
    /// layer and never touches disk.
    #if canImport(UIKit) && !os(watchOS)
    @State private var lastPoster: UIImage?
    #endif

    /// Inactivity window before the Stop-button chrome auto-hides.
    /// Three seconds matches the pattern AVKit, Photos, and Home use
    /// for their full-screen video surfaces — long enough to press,
    /// short enough to clear out of the way of the feed.
    private static let controlsAutoHideDelay: Duration = .seconds(3)

    public init(viewModel: LiveViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            backgroundView
            contentView
        }
        .accessibilityID(.liveRoot)
        .catlaserDynamicTypeBounds()
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: stateTag,
        )
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: controlsVisible,
        )
        .onChange(of: stateTag) { _, newValue in
            switch newValue {
            case "failed":
                errorFocus = true
                Haptics.error.play()
            case "streaming":
                // Success haptic the moment the first track lands —
                // the stream spinner-to-video transition is the
                // payoff the user was waiting for. The chrome is
                // visible and the auto-hide timer is armed by
                // ``streamingContent``'s ``.onAppear``.
                Haptics.success.play()
            default:
                break
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

    /// The live-stream itself fills the whole screen and renders on
    /// top of a black canvas — both appearances use a black
    /// under-layer so a LiveKit frame-drop shows black bars rather
    /// than the page background. This is the ONE intentional
    /// always-black surface in the app; everything else comes from
    /// ``SemanticColor``.
    private var backgroundView: some View {
        Color.black.ignoresSafeArea()
    }

    private var disconnectedContent: some View {
        ZStack {
            posterBackdrop
            VStack(spacing: 16) {
                Image(systemName: "video.slash")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityDecorativeIcon()
                Text(LiveViewStrings.disconnectedTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityHeader()
                Text(disconnectedSubtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button {
                    Haptics.commit.play()
                    Task { await viewModel.start() }
                } label: {
                    Text(LiveViewStrings.watchLiveButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(SemanticColor.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityID(.liveWatchButton)
                .accessibilityLabel(Text(LiveViewStrings.watchLiveButton))
            }
            .frame(maxWidth: 420)
            .padding()
        }
    }

    /// Blurred last-seen-frame backdrop rendered behind the
    /// ``disconnectedContent`` VStack. Uses the ``lastPoster`` cached
    /// on ``@State`` — captured by ``LiveVideoView`` on the previous
    /// stream's dismantle. When no poster exists yet (first Live tab
    /// visit this session, or after a shell rebuild) the backdrop is
    /// an empty view so the parent ``backgroundView`` (solid black)
    /// shows through unchanged.
    ///
    /// The blur + dark scrim is deliberately heavy: the source frame
    /// may contain people or interior detail we do not want to render
    /// as a legible photograph on the lock screen of a shared device.
    /// A 32-pt blur plus a 45% black scrim reduces the image to a
    /// tonal field — the user reads "that was your living room" from
    /// the dominant colour, not from any identifiable feature.
    @ViewBuilder
    private var posterBackdrop: some View {
        #if canImport(UIKit) && !os(watchOS)
        if let poster = lastPoster {
            Image(uiImage: poster)
                .resizable()
                .scaledToFill()
                .blur(radius: 32)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .accessibilityHidden(true)
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }

    /// Subtitle shown on the disconnected pane. Normally reads the
    /// first-time "tap Watch live" copy; after a biometric-cancel
    /// it reads the softened "couldn't confirm your identity" copy
    /// so the user knows the cancelled prompt — not a dead button —
    /// was what blocked the stream.
    private var disconnectedSubtitle: String {
        viewModel.didCancelAuthGate
            ? LiveViewStrings.disconnectedAuthCancelledSubtitle
            : LiveViewStrings.disconnectedSubtitle
    }

    private var loadingContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(.white)
                    .accessibilityLabel(Text(loadingLabel))
                // ``id(loadingLabel)`` forces SwiftUI to treat the
                // text as a fresh view when the label changes
                // (``requestingOffer`` → ``connecting``), so the
                // parent's animation crossfades between the two
                // phases. Without this the label string would silently
                // replace in place and a user staring at a slow
                // handshake would have no visual signal that the
                // phase advanced.
                Text(loadingLabel)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityAddTraits(.updatesFrequently)
                    .id(loadingLabel)
                    .transition(.opacity)
            }
            .accessibilityElement(children: .combine)

            // The VM exposes ``canStop`` as `true` throughout the
            // busy phases so a user who got stuck on a slow handshake
            // (slow cellular, sluggish device, server hiccup) can back
            // out without waiting for the 30-second connect watchdog.
            // Without this affordance the connecting state was a
            // dead-end the user could only escape by killing the app.
            Button {
                Haptics.light.play()
                Task { await viewModel.stop() }
            } label: {
                Text(LiveViewStrings.cancelConnectingButton)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityID(.liveCancelConnectingButton)
            .accessibilityLabel(Text(LiveViewStrings.cancelConnectingButton))
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
        ZStack(alignment: .top) {
            #if canImport(UIKit) && !os(watchOS)
            LiveVideoView(
                track: track,
                posterSink: { image in lastPoster = image },
            )
            .ignoresSafeArea()
            .accessibilityID(.liveVideo)
            .accessibilityLabel(Text(LiveViewStrings.videoAccessibilityLabel))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIgnoresInvertColors(true)
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            #else
            LiveVideoView(track: track)
                .ignoresSafeArea()
                .accessibilityID(.liveVideo)
                .accessibilityLabel(Text(LiveViewStrings.videoAccessibilityLabel))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIgnoresInvertColors(true)
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
            #endif

            if controlsVisible || voiceOverEnabled {
                overlayChrome
                    .transition(.opacity)
            }
        }
        .onAppear {
            controlsVisible = true
            scheduleAutoHide()
        }
        .onDisappear {
            controlsHideTask?.cancel()
            controlsHideTask = nil
        }
    }

    /// Top status pill + hopper badge overlay, and a bottom Stop
    /// button. Rendered above the video via a `ZStack` alignment and
    /// kept inside the safe area — the feed itself extends behind the
    /// home indicator, but controls never do.
    ///
    /// ``frame(maxWidth: .infinity, maxHeight: .infinity)`` makes the
    /// VStack stretch to the parent ZStack's bounds so the ``Spacer``
    /// between the top row and the bottom button has a definite
    /// height to claim; without it the VStack sizes to its intrinsic
    /// content and the Stop button would glue up against the top
    /// row.
    private var overlayChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                sessionStatusPill
                Spacer()
                if let badge = LiveSessionStatusStrings.hopperBadge(
                    for: viewModel.sessionStatus.hopperLevel,
                ) {
                    hopperBadge(label: badge, level: viewModel.sessionStatus.hopperLevel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            stopButton
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Session pill with an animated elapsed-time counter. A
    /// `TimelineView` ticks once per second for the "Playing now"
    /// phase; the idle / unknown phases render nothing — the chrome
    /// stays minimal when a session is not active so the feed reads
    /// as the primary content.
    @ViewBuilder
    private var sessionStatusPill: some View {
        let status = viewModel.sessionStatus
        switch status.phase {
        case .unknown, .idle:
            // Hide the pill for non-playing phases. ``idle`` used to
            // render an "Idle" label, but a status string leaking out
            // of the state machine into the production chrome reads
            // as a loading or half-working screen — Ring / Nest /
            // Eero all show no chrome when the feed is up but no
            // session is active. The only pill that should draw is
            // the ``playing`` counter.
            EmptyView()
        case .playing:
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let elapsed = status.sessionStartedAt.map { start in
                    LiveSessionStatusStrings.elapsed(
                        since: start,
                        now: context.date,
                    )
                }
                let spoken = status.sessionStartedAt.map { start in
                    LiveSessionStatusStrings.spokenElapsed(
                        since: start,
                        now: context.date,
                    )
                } ?? LiveSessionStatusStrings.playingLabel
                playingPillLabel(
                    label: elapsed.map { "\(LiveSessionStatusStrings.playingLabel) · \($0)" }
                        ?? LiveSessionStatusStrings.playingLabel,
                    dotColor: SemanticColor.success,
                    accessibility: LiveSessionStatusStrings.playingAccessibilityLabel(
                        elapsed: spoken,
                    ),
                )
            }
        }
    }

    private func playingPillLabel(
        label: String,
        dotColor: Color,
        accessibility: String,
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(SemanticColor.separator.opacity(0.5), lineWidth: 0.5),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func hopperBadge(
        label: String,
        level: Catlaser_App_V1_HopperLevel,
    ) -> some View {
        let tint: Color = switch level {
        case .empty: SemanticColor.destructive
        default: SemanticColor.warning
        }
        return HStack(spacing: 6) {
            Image(systemName: level == .empty ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(tint.opacity(0.75), lineWidth: 1),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
    }

    private var stopButton: some View {
        Button {
            Haptics.light.play()
            Task { await viewModel.stop() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .accessibilityHidden(true)
                Text(LiveViewStrings.stopButton)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityID(.liveStopButton)
        .accessibilityLabel(Text(LiveViewStrings.stopButton))
    }

    private var disconnectingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)
                .accessibilityLabel(Text(LiveViewStrings.disconnectingLabel))
            Text(LiveViewStrings.disconnectingLabel)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
    }

    private func failedContent(error: LiveViewError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(SemanticColor.warning)
                .accessibilityDecorativeIcon()
            Text(LiveViewStrings.failedTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityHeader()
            Text(LiveViewStrings.message(for: error))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .accessibilityFocused($errorFocus)
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
                .accessibilityID(.liveDismissButton)
                .accessibilityLabel(Text(LiveViewStrings.dismissButton))
                Button {
                    Haptics.commit.play()
                    Task {
                        viewModel.dismissError()
                        await viewModel.start()
                    }
                } label: {
                    Text(LiveViewStrings.retryButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(SemanticColor.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityID(.liveRetryButton)
                .accessibilityLabel(Text(LiveViewStrings.retryButton))
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }

    // MARK: - Tap-to-hide controls

    private func toggleControls() {
        // When VoiceOver is running, controls are pinned visible (the
        // overlay's conditional above renders chrome even when
        // ``controlsVisible`` is false) so the tap-to-hide gesture
        // would confuse screen-reader users. No-op in that case.
        guard !voiceOverEnabled else { return }
        controlsVisible.toggle()
        Haptics.selection.play()
        if controlsVisible {
            scheduleAutoHide()
        } else {
            controlsHideTask?.cancel()
            controlsHideTask = nil
        }
    }

    private func scheduleAutoHide() {
        controlsHideTask?.cancel()
        // Suppressed when VoiceOver is running — same rationale as
        // the tap gesture. The overlay is already forced visible by
        // the conditional, so skipping the timer avoids a redundant
        // MainActor state write that would otherwise fire on every
        // streaming tick.
        guard !voiceOverEnabled else { return }
        let delay = Self.controlsAutoHideDelay
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }
}
#endif
