#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
import Foundation

/// Semantic haptic feedback for user-initiated commits and
/// state-machine outcomes.
///
/// ## Why a semantic enum
///
/// Raw ``UIImpactFeedbackGenerator`` / ``UINotificationFeedbackGenerator``
/// calls sprinkled across views lose intent. A tap that commits to
/// "pair this device" and a tap that just dismisses a sheet both end
/// up with a `.light` impact; a successful pairing and a successful
/// sign-in end up with a hand-rolled `.success` each. Routing through
/// a semantic enum means the feel is consistent across screens — the
/// user experiences the same impact for "commit" everywhere — and a
/// single-site change (e.g. demoting `.commit` from medium to light)
/// re-tunes the whole app in one edit.
///
/// ## Usage
///
/// Call ``play()`` from the view layer on the user action or the
/// state transition that represents it:
///
///     Button {
///         Haptics.commit.play()
///         Task { await viewModel.save() }
///     } label: { Text("Save") }
///
/// For state-driven outcomes, hang ``play()`` off a SwiftUI
/// ``onChange`` that observes the VM's phase:
///
///     .onChange(of: viewModel.phase) { _, new in
///         if case .paired = new { Haptics.success.play() }
///     }
///
/// ## System settings + accessibility
///
/// iOS honours the user's *Settings → Sounds & Haptics → System
/// Haptics* toggle inside every ``UIFeedbackGenerator`` — when the
/// user has disabled haptics, ``play()`` is a silent no-op. No
/// runtime gate is required at the call site.
///
/// The separate *Accessibility → Motion → Reduce Motion* setting
/// does NOT suppress haptics (they are not motion). Haptics are
/// valuable feedback for VoiceOver users specifically, so
/// suppressing them based on reduce-motion would harm accessibility
/// — this module deliberately does not consult that flag.
///
/// ## Non-iOS platforms
///
/// On macOS, Linux SPM CI, and other non-iOS builds, ``play()``
/// compiles to a no-op. Callers never need to guard the call.
public enum Haptics: Sendable {
    /// Medium impact. The user has committed to an action — Pair,
    /// Save, Watch live, Sign in. Fire on tap so the device answers
    /// immediately, before any network round-trip. Most common case.
    case commit

    /// Light impact. Ancillary action — Stop stream, Resend link,
    /// Use different email, Dismiss. Use sparingly; these are nudges
    /// not commits.
    case light

    /// Selection-changed feedback. Reserved for discrete selection
    /// changes (segment picker, wheel) that aren't otherwise
    /// feedback-bearing. SwiftUI's ``Toggle`` and ``Picker`` already
    /// fire system haptics; prefer those unless building a custom
    /// control.
    case selection

    /// Notification-success. A committed action was confirmed by the
    /// system — pairing complete, stream connected, schedule saved.
    /// Fire on the VM state transition, not on the tap (the tap
    /// already played ``.commit``).
    case success

    /// Notification-warning. A destructive confirmation is about to
    /// fire, or an authorisation was denied. Fire at the destructive
    /// tap inside a confirmation dialog so the user's last-chance
    /// tap feels weighty.
    case warning

    /// Notification-error. A terminal failure surfaced in the UI — a
    /// failure banner became visible, the stream tore down with a
    /// typed error. Fire on the VM phase transition into
    /// ``.failed`` / equivalent so error banners announce themselves.
    case error

    /// Fire this haptic on the main thread. Pure presentation — no
    /// return value, no completion. Safe to call back-to-back; each
    /// impact is discrete.
    ///
    /// ``@MainActor`` because every ``UIFeedbackGenerator`` method
    /// must be invoked from the main thread; SwiftUI view actions
    /// already run there so the constraint is free at the call site.
    @MainActor
    public func play() {
        #if canImport(UIKit) && !os(watchOS)
        switch self {
        case .commit:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }
}
