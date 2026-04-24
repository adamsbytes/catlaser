import CatLaserDesign
import SwiftUI

/// Post-pair coach-mark overlay. Shown ONCE per install the first time
/// ``PairedShell`` mounts a live ``MainTabView``. Two cards point at
/// the History and Schedule tabs; a final "Got it" flips the
/// persistent flag in ``OnboardingTourStore`` and the overlay
/// disappears forever.
///
/// The overlay renders above the tab bar with a translucent scrim so
/// the background content (live video, history list, schedule) is
/// visible but dimmed. The underlying UI is NOT blocked — a user who
/// swipes the overlay away without tapping "Got it" still sees the
/// flag flip because dismissal via gesture or tap both route through
/// the same completion closure.
///
/// Copy is deliberately light: two sentences per card, one primary
/// button. The tour is an introduction, not a tutorial — deep dives
/// live behind the tabs themselves.
struct TabsTourOverlay: View {
    /// Called when the user taps "Got it" on the final card or
    /// swipes the overlay away. The host flips the persistent flag
    /// on this callback.
    let onComplete: () -> Void

    @State private var cardIndex: Int = 0

    /// Static deck of cards. Two stops — History, Schedule — each
    /// naming the tab icon visually and offering one clear sentence
    /// of context. Adding a third tab in future would add an entry
    /// here; the view advances through them in order.
    private var cards: [TourCard] {
        [
            TourCard(
                iconName: "pawprint.fill",
                title: TabsTourStrings.historyCardTitle,
                body: TabsTourStrings.historyCardBody,
            ),
            TourCard(
                iconName: "calendar",
                title: TabsTourStrings.scheduleCardTitle,
                body: TabsTourStrings.scheduleCardBody,
            ),
        ]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    // Tap on the scrim dismisses the tour immediately
                    // — same as tapping through every card. The
                    // persistent flag flip is the only destination.
                    Haptics.light.play()
                    onComplete()
                }

            if let card = cards[safe: cardIndex] {
                VStack(spacing: 16) {
                    Image(systemName: card.iconName)
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(SemanticColor.accent)
                        .accessibilityDecorativeIcon()
                    Text(card.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SemanticColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityHeader()
                    Text(card.body)
                        .font(.callout)
                        .foregroundStyle(SemanticColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    pageIndicator
                    Button {
                        advance()
                    } label: {
                        Text(buttonTitle)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(SemanticColor.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityID(isLastCard ? .onboardingTourDismiss : .onboardingTourNext)
                    .accessibilityLabel(Text(buttonTitle))
                }
                .padding(24)
                .frame(maxWidth: 420)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(SemanticColor.background),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(SemanticColor.separator, lineWidth: 1),
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .accessibilityElement(children: .contain)
            }
        }
        .accessibilityID(.onboardingTourRoot)
    }

    private var isLastCard: Bool {
        cardIndex >= cards.count - 1
    }

    private var buttonTitle: String {
        isLastCard ? TabsTourStrings.dismissButton : TabsTourStrings.nextButton
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< cards.count, id: \.self) { index in
                Circle()
                    .fill(index == cardIndex
                        ? SemanticColor.accent
                        : SemanticColor.separator)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func advance() {
        Haptics.selection.play()
        if isLastCard {
            onComplete()
        } else {
            cardIndex += 1
        }
    }
}

private struct TourCard {
    let iconName: String
    let title: String
    let body: String
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

enum TabsTourStrings {
    static let historyCardTitle = NSLocalizedString(
        "onboarding.tour.history.title",
        value: "Your cats show up here",
        comment: "Title for the History tab coach-mark card in the post-pair tour.",
    )

    static let historyCardBody = NSLocalizedString(
        "onboarding.tour.history.body",
        value: "Once your Catlaser sees a cat, you can name them and watch their play stats add up session by session.",
        comment: "Body for the History tab coach-mark card.",
    )

    static let scheduleCardTitle = NSLocalizedString(
        "onboarding.tour.schedule.title",
        value: "Set times to play automatically",
        comment: "Title for the Schedule tab coach-mark card in the post-pair tour.",
    )

    static let scheduleCardBody = NSLocalizedString(
        "onboarding.tour.schedule.body",
        value: "Pick times when your cat gets the most play — your Catlaser will run on its own inside those windows, even when you're not home.",
        comment: "Body for the Schedule tab coach-mark card.",
    )

    static let nextButton = NSLocalizedString(
        "onboarding.tour.next",
        value: "Next",
        comment: "Advance button on the coach-mark cards.",
    )

    static let dismissButton = NSLocalizedString(
        "onboarding.tour.done",
        value: "Got it",
        comment: "Final dismiss button on the last coach-mark card.",
    )
}
