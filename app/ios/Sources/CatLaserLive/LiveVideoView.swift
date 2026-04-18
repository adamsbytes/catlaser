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

/// SwiftUI wrapper that renders a `LiveVideoTrackHandle`.
///
/// When LiveKit is available, the wrapper materialises a
/// `LiveKit.VideoView` and attaches the subscribed track. When
/// LiveKit is not linked (e.g. previews, unit tests on mocks), the
/// wrapper renders a grey placeholder so the rest of the UI still
/// composes correctly.
struct LiveVideoView: View {
    let track: any LiveVideoTrackHandle

    var body: some View {
        #if canImport(LiveKit)
        if let live = track as? LiveKitVideoTrackHandle {
            LiveKitRenderer(track: live.track)
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

#if canImport(UIKit) && !os(watchOS)
private struct LiveKitRenderer: UIViewRepresentable {
    let track: VideoTrack

    func makeUIView(context _: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fit
        view.mirrorMode = .off
        view.track = track
        return view
    }

    func updateUIView(_ view: VideoView, context _: Context) {
        if view.track?.id != track.id {
            view.track = track
        }
    }

    static func dismantleUIView(_ view: VideoView, coordinator _: Void) {
        view.track = nil
    }
}
#elseif canImport(AppKit)
private struct LiveKitRenderer: NSViewRepresentable {
    let track: VideoTrack

    func makeNSView(context _: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fit
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
