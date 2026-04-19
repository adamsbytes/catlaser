import CatLaserDesign
import SwiftUI

/// Shown for the tiny window between first scene mount and the
/// completion of ``AppState/bootstrapIfNeeded()``.
///
/// On a cold launch the composition construction hits the Secure
/// Enclave, the keychain, and the first cache-read of the consent
/// store — all fast but not instant, and none of which we want to
/// front-load onto the launch-screen storyboard path. A SwiftUI
/// placeholder that shows the app tint immediately avoids the
/// "black screen between storyboard and first view" flash iOS users
/// associate with a crashed or slow app.
///
/// Kept trivial on purpose: no text, no spinner, no branding beyond
/// the accent tint. The storyboard launch image has already
/// communicated "the app started." This view is the bridge.
struct LaunchPlaceholder: View {
    var body: some View {
        ZStack {
            SemanticColor.background
                .ignoresSafeArea()
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityHidden(true)
        }
    }
}
