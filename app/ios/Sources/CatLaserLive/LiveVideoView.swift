#if canImport(SwiftUI)
import Foundation
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(LiveKit)
import LiveKit
#endif

/// Callback fired when the live-video surface is torn down.
///
/// The host passes in an optional sink to receive the last rendered
/// frame as a ``UIImage`` (Darwin) — used to paint a "last-seen
/// poster" behind the disconnected pane on the next visit to the
/// Live tab. Non-UIKit platforms ignore the payload because they
/// have no image type for a poster at this layer.
#if canImport(UIKit) && !os(watchOS)
typealias LivePosterSink = @MainActor (UIImage?) -> Void
#endif

/// SwiftUI wrapper that renders a `LiveVideoTrackHandle`.
///
/// When LiveKit is available, the wrapper materialises a
/// `LiveKit.VideoView` and attaches the subscribed track. When
/// LiveKit is not linked (e.g. previews, unit tests on mocks), the
/// wrapper renders a grey placeholder so the rest of the UI still
/// composes correctly.
///
/// The optional ``posterSink`` (UIKit only) is invoked once as the
/// underlying ``VideoView`` is dismantled — the SwiftUI lifecycle
/// point at which the track subscription is about to be torn down.
/// The last rendered frame is captured via ``drawHierarchy`` into a
/// downsampled ``UIImage`` so the host can render a blurred poster
/// behind the disconnected pane on the user's next visit to the
/// Live tab.
struct LiveVideoView: View {
    let track: any LiveVideoTrackHandle
    #if canImport(UIKit) && !os(watchOS)
    var posterSink: LivePosterSink?
    #endif

    var body: some View {
        #if canImport(LiveKit)
        if let live = track as? LiveKitVideoTrackHandle {
            #if canImport(UIKit) && !os(watchOS)
            LiveKitRenderer(track: live.track, posterSink: posterSink)
            #else
            LiveKitRenderer(track: live.track)
            #endif
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    private var placeholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
                Text(LiveViewStrings.videoAccessibilityLabel)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

#if canImport(LiveKit)

// ``.fill`` crops the 4:3 camera feed to the view's aspect ratio so
// the video fills the screen edge-to-edge rather than floating in a
// letterboxed black canvas. The black under-layer on ``LiveView`` is
// kept for frame-drop cover — a dropped frame still shows black, but
// a steady stream reads as "premium full-bleed feed" instead of
// "something is wrong with the loading state." The camera sensor
// over-captures the framing a user actually wants by design (tracker
// bbox centring), so clipping the vertical edges on a 16:9 phone and
// the horizontal edges in landscape does not remove anything the
// user was meant to see.
#if canImport(UIKit) && !os(watchOS)
private struct LiveKitRenderer: UIViewRepresentable {
    let track: VideoTrack
    let posterSink: LivePosterSink?

    /// Max edge length of the captured poster. The live feed is
    /// typically 720p / 1080p; a full-resolution snapshot would
    /// burn ~8 MB of RAM just to be blurred and re-rendered at
    /// screen scale. 640 pt captures enough detail for a blurred
    /// backdrop while keeping the cached image under 2 MB even on
    /// a 3x device.
    static let posterMaxEdge: CGFloat = 640

    func makeCoordinator() -> Coordinator {
        Coordinator(posterSink: posterSink)
    }

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fill
        view.mirrorMode = .off
        view.track = track
        context.coordinator.videoView = view
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        if view.track?.id != track.id {
            view.track = track
        }
        context.coordinator.videoView = view
    }

    /// On dismantle, capture the last rendered frame as a ``UIImage``
    /// downsampled to ``posterMaxEdge`` on its longer edge, hand it to
    /// the host-supplied sink, and null the track.
    ///
    /// The sink is always invoked — including with ``nil`` — so the
    /// host can clear any stale poster if the current teardown path
    /// reached dismantle with no renderable frame (e.g. a stream that
    /// torn down before the first frame ever painted). The capture
    /// lives in memory only; the sink is expected to keep the image
    /// off disk so a future privacy review sees nothing persisted.
    static func dismantleUIView(_ view: VideoView, coordinator: Coordinator) {
        let image = capturedPoster(from: view)
        view.track = nil
        if let sink = coordinator.posterSink {
            // ``dismantleUIView`` runs on the main thread per SwiftUI
            // contract, but the closure's ``@MainActor`` annotation
            // is opaque to the compiler here — hop through
            // ``MainActor.assumeIsolated`` to satisfy strict
            // concurrency without an actor-hop round-trip.
            MainActor.assumeIsolated { sink(image) }
        }
    }

    /// Snapshot the view hierarchy at the current moment into a
    /// downsampled ``UIImage``. Returns ``nil`` when the view has no
    /// bounds (i.e. never laid out — for instance a scene that
    /// backgrounded before the live tab first drew).
    ///
    /// ``drawHierarchy(in:afterScreenUpdates:)`` is the one snapshot
    /// API that captures Metal-backed content, which is what LiveKit's
    /// renderer uses under the hood. ``snapshotView(afterScreenUpdates:)``
    /// would only return an opaque UIView mirror, and ``layer.render(in:)``
    /// misses Metal layers entirely.
    private static func capturedPoster(from view: VideoView) -> UIImage? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }

        let longestEdge = max(size.width, size.height)
        let scale = longestEdge > posterMaxEdge ? posterMaxEdge / longestEdge : 1.0
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        // Force screen-scale 1 on the renderer so ``targetSize`` is
        // the exact point size of the image; otherwise the renderer
        // would multiply by the device scale factor and we'd be back
        // to the ~8 MB regime we came here to avoid.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            // Draw into the renderer's context at the downscaled
            // target size; UIKit compositing handles the scaling
            // inside ``drawHierarchy`` without producing intermediate
            // buffers at the source resolution.
            view.drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: false)
        }
    }

    /// Bridge for the coordinator so a ``static`` ``dismantleUIView``
    /// can reach the sink set at ``makeUIView`` time. The weak
    /// ``videoView`` reference is incidental — the dismantle call
    /// always gets the view as a parameter — but we keep it so the
    /// coordinator can grow capabilities (e.g. a caller that needs
    /// on-demand captures mid-stream) without revisiting the
    /// representable's shape.
    final class Coordinator {
        weak var videoView: VideoView?
        let posterSink: LivePosterSink?

        init(posterSink: LivePosterSink?) {
            self.posterSink = posterSink
        }
    }
}
#elseif canImport(AppKit)
private struct LiveKitRenderer: NSViewRepresentable {
    let track: VideoTrack

    func makeNSView(context _: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fill
        view.mirrorMode = .off
        view.track = track
        return view
    }

    func updateNSView(_ view: VideoView, context _: Context) {
        if view.track?.id != track.id {
            view.track = track
        }
    }

    static func dismantleNSView(_ view: VideoView, coordinator _: Void) {
        view.track = nil
    }
}
#endif

#endif
#endif
