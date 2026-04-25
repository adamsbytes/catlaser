#if canImport(SwiftUI)
import CatLaserDesign
import CatLaserProto
import Foundation
import SwiftUI

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftUI history + cat-profiles screen.
///
/// Two panes (cats, sessions) selected by a segmented control. Every
/// control on screen binds to a ``HistoryViewModel`` method or
/// observable property — the view holds no local state of its own
/// beyond the selected segment. Tests therefore exercise the VM
/// directly and this view is a thin presentation layer whose
/// correctness is "control wired to VM action and VM property wired
/// to control state."
public struct HistoryView: View {
    /// Two-way segment binding. The selected pane lives in view
    /// state because it is a pure presentation choice — neither pane
    /// stops loading when hidden.
    public enum Pane: Sendable, Hashable {
        case cats
        case sessions
    }

    @Bindable private var viewModel: HistoryViewModel
    @State private var selectedPane: Pane = .cats
    @State private var editingProfile: Catlaser_App_V1_CatProfile?
    @State private var pendingDeletion: Catlaser_App_V1_CatProfile?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var errorFocus: Bool

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                segmentControl
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                paneContent
            }
            if let error = viewModel.lastActionError {
                actionErrorOverlay(error: error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .accessibilityID(.historyRoot)
        .catlaserDynamicTypeBounds()
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: viewModel.lastActionError,
        )
        .onChange(of: viewModel.lastActionError) { _, newValue in
            if newValue != nil {
                errorFocus = true
                Haptics.error.play()
            }
        }
        .sheet(item: $editingProfile) { profile in
            EditCatSheet(
                profile: profile,
                viewModel: viewModel,
                onDismiss: { editingProfile = nil },
            )
        }
        .sheet(item: Binding(
            get: { viewModel.pendingNewCats.first },
            set: { newValue in
                // A nil write is SwiftUI telling us the sheet was
                // dismissed interactively (swipe down). Route the
                // nil through the VM so the queue actually pops —
                // otherwise the binding would re-render from the
                // still-present head prompt and the sheet would
                // spring back up the next time the view updates.
                // Non-nil writes would be SwiftUI asking us to switch
                // identity mid-sheet, which cannot happen for a queue
                // we own; ignore them as structurally unreachable.
                guard newValue == nil,
                      let head = viewModel.pendingNewCats.first else { return }
                viewModel.dismissNewCatPrompt(head.trackIDHint)
            },
        )) { prompt in
            NameNewCatSheet(
                prompt: prompt,
                // The head prompt is always queue position 1; the
                // total is the current queue depth. Captured at sheet
                // construction rather than observed live so a second
                // prompt landing mid-naming doesn't bump the total
                // under the user's finger — they get to finish naming
                // the cat in front of them before the counter ticks.
                // The SwiftUI ``.sheet(item:)`` API rebuilds the body
                // whenever ``item`` identity changes, so the next
                // prompt's sheet will read the updated depth at mount.
                queueTotal: viewModel.pendingNewCats.count,
                viewModel: viewModel,
            )
        }
        .sheet(isPresented: celebrationPresentationBinding) {
            // `pendingSessionCelebration` is the source of truth; the
            // body reads it back as a non-optional inside the closure
            // (the Binding's getter guarantees non-nil whenever this
            // closure fires). A nil-check defensively shields against
            // a vanishingly-rare race in which the view rebuilds
            // between binding-true and closure-execution; if the
            // value is gone we render nothing rather than a placeholder
            // sheet.
            if let summary = viewModel.pendingSessionCelebration {
                SessionCelebrationSheet(
                    summary: summary,
                    profiles: loadedProfiles,
                    onDismiss: { viewModel.dismissSessionCelebration() },
                )
            }
        }
        .onChange(of: viewModel.pendingSessionCelebration) { _, newValue in
            // Pair the sheet presentation with the success haptic the
            // user already feels at session start. The celebration is
            // the payoff moment; the haptic is what makes it feel
            // earned rather than informational.
            if newValue != nil {
                Haptics.success.play()
            }
        }
        .confirmationDialog(
            HistoryStrings.catRowDeleteConfirmTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } },
            ),
            presenting: pendingDeletion,
        ) { profile in
            Button(HistoryStrings.catRowDeleteConfirmAction, role: .destructive) {
                Haptics.warning.play()
                Task {
                    let target = profile
                    pendingDeletion = nil
                    _ = await viewModel.deleteCat(catID: target.catID)
                }
            }
            Button(HistoryStrings.editCancelButton, role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text(HistoryStrings.catRowDeleteConfirmBody)
        }
        .task {
            await viewModel.start()
        }
    }

    // MARK: - Celebration sheet plumbing

    /// Boolean bridge for the celebration sheet's ``isPresented``.
    /// The optional ``pendingSessionCelebration`` is the source of
    /// truth; SwiftUI writes ``false`` on dismiss (interactive swipe
    /// or programmatic close), and the setter routes that back through
    /// the VM so the optional clears in one place. A ``true`` write
    /// is structurally unreachable for a binding the view owns —
    /// SwiftUI only writes ``true`` via the trailing closure's own
    /// presentation, which is already gated by the optional.
    private var celebrationPresentationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingSessionCelebration != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissSessionCelebration()
                }
            },
        )
    }

    /// The currently-loaded profile catalogue, surfaced from
    /// ``catsState`` for use by the celebration sheet's name
    /// resolution. Returns an empty array when the cat list has not
    /// loaded yet — the sheet renders the "A cat just played"
    /// fallback in that case rather than blocking on a refetch.
    private var loadedProfiles: [Catlaser_App_V1_CatProfile] {
        if case let .loaded(profiles, _) = viewModel.catsState {
            return profiles
        }
        return []
    }

    // MARK: - Segment

    private var segmentControl: some View {
        Picker(HistoryStrings.screenTitle, selection: $selectedPane) {
            Text(HistoryStrings.segmentCats).tag(Pane.cats)
            Text(HistoryStrings.segmentSessions).tag(Pane.sessions)
        }
        .pickerStyle(.segmented)
        .accessibilityID(.historyPaneSegment)
        .accessibilityLabel(Text(HistoryStrings.screenTitle))
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .cats:
            catsPane
        case .sessions:
            sessionsPane
        }
    }

    // MARK: - Cats pane

    @ViewBuilder
    private var catsPane: some View {
        switch viewModel.catsState {
        case .idle, .loading:
            // Skeleton rows feel ~2x faster than a centred spinner —
            // the user sees the right shape immediately and the
            // perceived load time collapses to the time it takes for
            // the real rows to appear in place. Six rows is enough to
            // fill a phone screen without reaching the bottom of the
            // safe area on a Pro Max.
            skeletonScroll {
                CatProfileSkeletonRow()
            }
            .accessibilityLabel(Text(HistoryStrings.catListLoadingLabel))
        case let .loaded(profiles, isRefreshing):
            if profiles.isEmpty {
                emptyPane(
                    iconName: "pawprint",
                    title: HistoryStrings.catListEmptyTitle,
                    subtitle: HistoryStrings.catListEmptySubtitle,
                )
            } else {
                catsList(profiles: profiles, isRefreshing: isRefreshing)
            }
        case let .failed(error):
            failedPane(
                error: error,
                onRetry: { Task { await viewModel.refreshCats() } },
            )
        }
    }

    private func catsList(
        profiles: [Catlaser_App_V1_CatProfile],
        isRefreshing: Bool,
    ) -> some View {
        // Native ``List`` rather than the previous ``ScrollView`` so
        // SwiftUI's ``.swipeActions`` modifier engages — that is the
        // iOS-native gesture for row-level actions and what users
        // reach for first on every other shipping app. The plain
        // style + cleared row chrome preserves the previous card-on-
        // background visual; ``.scrollContentBackground(.hidden)``
        // lets the parent's ``SemanticColor.background`` show through.
        List {
            ForEach(profiles, id: \.catID) { profile in
                CatProfileRow(
                    profile: profile,
                    onEdit: { editingProfile = profile },
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeletion = profile
                    } label: {
                        Label(
                            HistoryStrings.catRowDeleteButton,
                            systemImage: "trash",
                        )
                    }
                    Button {
                        editingProfile = profile
                    } label: {
                        Label(
                            HistoryStrings.catRowEditButton,
                            systemImage: "pencil",
                        )
                    }
                    .tint(SemanticColor.accent)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(SemanticColor.background)
        .overlay(alignment: .top) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(HistoryStrings.catListLoadingLabel))
                    .padding(.top, 8)
            }
        }
        .refreshable {
            await viewModel.refreshCats()
        }
    }

    // MARK: - Sessions pane

    @ViewBuilder
    private var sessionsPane: some View {
        switch viewModel.historyState {
        case .idle, .loading:
            skeletonScroll {
                PlaySessionSkeletonRow()
            }
            .accessibilityLabel(Text(HistoryStrings.sessionsLoadingLabel))
        case let .loaded(sessions, _, isRefreshing):
            if sessions.isEmpty {
                emptyPane(
                    iconName: "calendar.badge.clock",
                    title: HistoryStrings.sessionsEmptyTitle,
                    subtitle: HistoryStrings.sessionsEmptySubtitle,
                )
            } else {
                sessionsList(sessions: sessions, isRefreshing: isRefreshing)
            }
        case let .failed(error, _):
            failedPane(
                error: error,
                onRetry: { Task { await viewModel.refreshHistory() } },
            )
        }
    }

    private func sessionsList(
        sessions: [Catlaser_App_V1_PlaySession],
        isRefreshing: Bool,
    ) -> some View {
        let profiles: [Catlaser_App_V1_CatProfile]
        if case let .loaded(loadedProfiles, _) = viewModel.catsState {
            profiles = loadedProfiles
        } else {
            profiles = []
        }
        // Native ``List`` (matching ``catsList``) so pull-to-refresh
        // engages the system-standard rubberband behaviour and the
        // refresh trigger threshold is consistent across both panes.
        // Plain style + cleared row chrome preserves the previous
        // card-on-background look; ``scrollContentBackground(.hidden)``
        // lets the parent's ``SemanticColor.background`` show through.
        return List {
            ForEach(sessions, id: \.sessionID) { session in
                PlaySessionRow(session: session, profiles: profiles)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(SemanticColor.background)
        .overlay(alignment: .top) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(HistoryStrings.sessionsLoadingLabel))
                    .padding(.top, 8)
            }
        }
        .refreshable {
            await viewModel.refreshHistory()
        }
    }

    // MARK: - Pane chrome

    /// Skeleton placeholder list shown during initial loads. Renders
    /// six instances of the supplied row inside the same scroll-view
    /// chrome the real list uses, then applies a redacted-placeholder
    /// reason so the system paints a uniform grey wash. The whole
    /// container becomes a single combined accessibility element that
    /// announces "Loading content" — VoiceOver users get one clean
    /// announcement instead of six redundant readings of the
    /// placeholder rows.
    private func skeletonScroll<Row: View>(@ViewBuilder _ row: () -> Row) -> some View {
        let prototypeRow = row()
        return ScrollView {
            VStack(spacing: 12) {
                ForEach(0 ..< 6, id: \.self) { _ in
                    prototypeRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .redacted(reason: .placeholder)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(HistoryStrings.skeletonAccessibility))
            .accessibilityAddTraits(.updatesFrequently)
        }
        .scrollDisabled(true)
    }

    private func emptyPane(iconName: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: iconName)
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(SemanticColor.textTertiary)
                .accessibilityDecorativeIcon()
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    private func failedPane(error: HistoryError, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(SemanticColor.warning)
                .accessibilityDecorativeIcon()
            Text(HistoryStrings.errorBannerTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(HistoryStrings.message(for: error))
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(HistoryStrings.retryButton, action: onRetry)
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(SemanticColor.accent, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityID(.historyRetry)
                .accessibilityLabel(Text(HistoryStrings.retryButton))
            Spacer()
        }
    }

    private func actionErrorOverlay(error: HistoryError) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(SemanticColor.warning)
                    .accessibilityHidden(true)
                Text(HistoryStrings.message(for: error))
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textPrimary)
                    .lineLimit(3)
                    .accessibilityFocused($errorFocus)
                Spacer()
                Button(HistoryStrings.dismissButton) {
                    viewModel.dismissActionError()
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityID(.historyDismissError)
                .accessibilityLabel(Text(HistoryStrings.dismissButton))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Cat row

private struct CatProfileRow: View {
    let profile: Catlaser_App_V1_CatProfile
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailImage(data: profile.thumbnail, fallbackIcon: "pawprint.fill")
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name.isEmpty ? HistoryStrings.sessionRowUnknownCat : profile.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                Text(CatProfileFormatter.sessionsString(count: profile.totalSessions))
                    .font(.caption)
                    .foregroundStyle(SemanticColor.textSecondary)
                Text(
                    CatProfileFormatter.playTimeString(secondsTotal: profile.totalPlayTimeSec)
                        + " • "
                        + CatProfileFormatter.treatsString(count: profile.totalTreats),
                )
                .font(.caption)
                .foregroundStyle(SemanticColor.textSecondary)
            }
            Spacer()
            // Subtle chevron echoes Mail / Reminders / Contacts —
            // signals that the row is interactive without consuming
            // horizontal space the way the previous inline button
            // pair did, and stays consistent with the system
            // convention "tap drills in, swipe acts."
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SemanticColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 16))
        // ``contentShape`` makes the entire card tappable so the user
        // can hit any pixel of the row — not just the text — to open
        // the edit sheet. The destructive Delete and the Edit actions
        // both remain available via the parent's ``swipeActions``,
        // matching the iOS-native row-action convention.
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: onEdit)
        .accessibilityID(.historyCatRow)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(HistoryStrings.catRowTapHint))
    }
}

// MARK: - Session row

private struct PlaySessionRow: View {
    let session: Catlaser_App_V1_PlaySession
    let profiles: [Catlaser_App_V1_CatProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(CatProfileFormatter.sessionCatsSummary(
                    catIDs: session.catIds,
                    profiles: profiles,
                ))
                .font(.body.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                Spacer()
                Text(CatProfileFormatter.sessionDateString(epochSeconds: session.startTime))
                    .font(.caption)
                    .foregroundStyle(SemanticColor.textTertiary)
            }
            HStack(spacing: 16) {
                statBlock(
                    icon: "clock",
                    label: CatProfileFormatter.playTimeString(secondsTotal: session.durationSec),
                    accessibility: nil,
                )
                statBlock(
                    icon: "bolt.fill",
                    // Replaces the previous bare "%.0f%%" render — a
                    // raw percentage carried no scale for the owner.
                    // The bucket label ("Very playful" / "Playful" /
                    // "Mild interest") reads as a meaningful summary
                    // on its own; VoiceOver still hears the percent
                    // via the accessibility variant so the underlying
                    // signal is not hidden from screen-reader users.
                    label: CatProfileFormatter.engagementLabel(score: session.engagementScore),
                    accessibility: CatProfileFormatter.engagementAccessibilityLabel(
                        score: session.engagementScore,
                    ),
                )
                statBlock(
                    icon: "circle.grid.cross",
                    label: "\(session.pounceCount)",
                    accessibility: nil,
                )
                statBlock(
                    icon: "fork.knife",
                    label: "\(session.treatsDispensed)",
                    accessibility: nil,
                )
            }
            .font(.caption)
            .foregroundStyle(SemanticColor.textSecondary)
        }
        .padding(12)
        .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityID(.historySessionRow)
        .accessibilityElement(children: .combine)
    }

    /// Stat-row icon + label pair. ``accessibility`` overrides the
    /// label for the spoken pass when the visual rendering elides
    /// information a VoiceOver user needs (the engagement bucket
    /// drops the percentage; supplying it on the spoken path keeps
    /// the underlying signal addressable).
    private func statBlock(
        icon: String,
        label: String,
        accessibility: String?,
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibility ?? label))
    }
}

// MARK: - Edit sheet

private struct EditCatSheet: View {
    let profile: Catlaser_App_V1_CatProfile
    let viewModel: HistoryViewModel
    let onDismiss: () -> Void

    @State private var draft: String
    @State private var isSubmitting = false
    @State private var validationError: String?

    init(
        profile: Catlaser_App_V1_CatProfile,
        viewModel: HistoryViewModel,
        onDismiss: @escaping () -> Void,
    ) {
        self.profile = profile
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        self._draft = State(initialValue: profile.name)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(HistoryStrings.editNameLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SemanticColor.textSecondary)
                TextField(HistoryStrings.editNamePlaceholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                    .submitLabel(.done)
                    .onSubmit {
                        // Keyboard return on the sole text field is
                        // the obvious commit gesture; mirror what the
                        // Save button does. The Save button stays the
                        // canonical entry point — this is just a
                        // shortcut for users on the keyboard.
                        guard !isSubmitting, canSubmit else { return }
                        Haptics.commit.play()
                        Task { await submit() }
                    }
                    .accessibilityID(.historyEditNameField)
                    .accessibilityLabel(Text(HistoryStrings.editNameLabel))
                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(SemanticColor.destructive)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(HistoryStrings.editSheetTitle)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button(HistoryStrings.editCancelButton, action: onDismiss)
                            .disabled(isSubmitting)
                            .accessibilityID(.historyEditCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        saveButton
                    }
                    #else
                    ToolbarItem {
                        Button(HistoryStrings.editCancelButton, action: onDismiss)
                            .disabled(isSubmitting)
                            .accessibilityID(.historyEditCancel)
                    }
                    ToolbarItem {
                        saveButton
                    }
                    #endif
                }
        }
        // Edit sheet is a single field + buttons — full-screen would
        // hide the underlying list pointlessly. ``.medium`` brings up
        // a half sheet that keeps context visible; ``.large`` lets
        // the user expand if they want more breathing room or if
        // dynamic-type pushes the layout.
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var saveButton: some View {
        Button(HistoryStrings.editSaveButton) {
            Haptics.commit.play()
            Task { await submit() }
        }
        .disabled(isSubmitting || !canSubmit)
        .accessibilityID(.historyEditSave)
        .accessibilityLabel(Text(HistoryStrings.editSaveButton))
    }

    private var canSubmit: Bool {
        if case .success = HistoryViewModel.validateName(draft) { return true }
        return false
    }

    private func submit() async {
        isSubmitting = true
        validationError = nil
        let outcome = await viewModel.updateCatName(profile, newName: draft)
        isSubmitting = false
        switch outcome {
        case .success:
            onDismiss()
        case let .failure(error):
            if case let .validation(message) = error {
                validationError = message
            } else {
                // The action banner on the parent surfaces non-validation
                // errors. Close the sheet so the user sees the banner
                // and can retry the action.
                onDismiss()
            }
        }
    }
}

// MARK: - New-cat naming sheet

private struct NameNewCatSheet: View {
    let prompt: NewCatPrompt
    /// Total pending-prompt queue depth observed when the sheet was
    /// constructed. Drives the "1 of N" affordance on the title so a
    /// user who was away while multiple new cats were detected
    /// understands the sheet is going to re-present N-1 more times
    /// rather than assuming it's stuck in a loop. Always ``>= 1`` —
    /// the sheet wouldn't mount at all if the queue were empty.
    let queueTotal: Int
    let viewModel: HistoryViewModel

    @State private var draft: String = ""
    @State private var isSubmitting = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                ThumbnailImage(data: prompt.thumbnail, fallbackIcon: "pawprint.fill")
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(Text(HistoryStrings.namingThumbnailAccessibility))
                Text(HistoryStrings.namingSheetBody)
                    .font(.body)
                    .foregroundStyle(SemanticColor.textPrimary)
                Text(HistoryStrings.namingNameLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SemanticColor.textSecondary)
                TextField(HistoryStrings.editNamePlaceholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit {
                        guard !isSubmitting, canSubmit else { return }
                        Haptics.commit.play()
                        Task { await submit() }
                    }
                    .accessibilityID(.historyNewCatNameField)
                    .accessibilityLabel(Text(HistoryStrings.namingNameLabel))
                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(SemanticColor.destructive)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(sheetTitle)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button(HistoryStrings.namingDismissButton) {
                            viewModel.dismissNewCatPrompt(prompt.trackIDHint)
                        }
                        .disabled(isSubmitting)
                        .accessibilityID(.historyNewCatDismiss)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        saveButton
                    }
                    #else
                    ToolbarItem {
                        Button(HistoryStrings.namingDismissButton) {
                            viewModel.dismissNewCatPrompt(prompt.trackIDHint)
                        }
                        .disabled(isSubmitting)
                        .accessibilityID(.historyNewCatDismiss)
                    }
                    ToolbarItem {
                        saveButton
                    }
                    #endif
                }
        }
        // Naming sheet has a thumbnail + body copy + a single field —
        // medium sheet keeps the underlying cat list visible at the
        // top while the user names the cat, large is available for
        // accessibility-size users.
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var saveButton: some View {
        Button(HistoryStrings.namingSaveButton) {
            Haptics.commit.play()
            Task { await submit() }
        }
        .disabled(isSubmitting || !canSubmit)
        .accessibilityID(.historyNewCatSave)
        .accessibilityLabel(Text(HistoryStrings.namingSaveButton))
    }

    private var canSubmit: Bool {
        if case .success = HistoryViewModel.validateName(draft) { return true }
        return false
    }

    /// Sheet title — falls back to the plain "New cat seen" copy for
    /// a single queued prompt; adds the "1 of N" progress affordance
    /// when multiple cats are queued. The head prompt is always queue
    /// position 1 because the FIFO pops on dismiss or save, so the
    /// index is a constant rather than a computed property.
    private var sheetTitle: String {
        if queueTotal > 1 {
            return HistoryStrings.namingSheetTitleWithQueue(index: 1, total: queueTotal)
        }
        return HistoryStrings.namingSheetTitle
    }

    private func submit() async {
        isSubmitting = true
        validationError = nil
        let outcome = await viewModel.identifyNewCat(prompt, name: draft)
        isSubmitting = false
        if case let .failure(error) = outcome, case let .validation(message) = error {
            validationError = message
        }
        // The VM removes the prompt on success and on `NOT_FOUND`;
        // the sheet binding observes ``pendingNewCats.first`` and
        // dismisses automatically when it changes.
    }
}

// MARK: - Skeleton placeholder rows

/// Cat-row skeleton used during the initial cats-pane load. The shape
/// matches ``CatProfileRow`` exactly (thumbnail square + three text
/// lines + two action chips on the trailing edge) so when the real
/// rows arrive there is no visible jump in layout. Painted in a
/// single neutral fill — the parent applies ``.redacted(reason:
/// .placeholder)`` so SwiftUI takes care of the placeholder wash.
private struct CatProfileSkeletonRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(SemanticColor.elevatedFill)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 96, height: 10)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 180, height: 10)
            }
            Spacer()
            // Match the live row's trailing chevron so the real row
            // lands without a layout shift on the trailing edge when
            // the load completes.
            RoundedRectangle(cornerRadius: 2)
                .fill(SemanticColor.elevatedFill)
                .frame(width: 8, height: 14)
        }
        .padding(12)
        .background(
            SemanticColor.groupedBackground,
            in: RoundedRectangle(cornerRadius: 16),
        )
    }
}

/// Sessions-row skeleton used during the initial sessions-pane load.
/// Matches the layout of ``PlaySessionRow`` (header line with cat-
/// summary + date, four stat blocks beneath).
private struct PlaySessionSkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 140, height: 14)
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 80, height: 10)
            }
            HStack(spacing: 16) {
                ForEach(0 ..< 4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(SemanticColor.elevatedFill)
                        .frame(width: 36, height: 10)
                }
            }
        }
        .padding(12)
        .background(
            SemanticColor.groupedBackground,
            in: RoundedRectangle(cornerRadius: 16),
        )
    }
}

// MARK: - Thumbnail helper

private struct ThumbnailImage: View {
    let data: Data
    let fallbackIcon: String

    var body: some View {
        Group {
            if let image = decode(data) {
                image
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors(true)
            } else {
                ZStack {
                    SemanticColor.groupedBackground
                    Image(systemName: fallbackIcon)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(SemanticColor.textTertiary)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func decode(_ data: Data) -> Image? {
        guard !data.isEmpty else { return nil }
        #if canImport(UIKit) && !os(watchOS)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #endif
        return nil
    }
}

// MARK: - Session celebration sheet

/// One-shot post-session celebration. Renders when the device emits an
/// unsolicited ``SessionSummary`` (the moment a play session ends),
/// surfacing the headline stats — engagement bucket, play time, pounce
/// count, treats — alongside the cat's name.
///
/// This is the in-app counterpart to the FCM push that fires for the
/// same event. Push delivers the news on the lock screen; tapping the
/// push routes the user to the History tab where this sheet is the
/// payoff. A user who already has the app open hears the haptic and
/// sees the sheet without ever leaving the screen they were on.
///
/// The sheet is mounted by ``HistoryView`` against the VM's
/// ``pendingSessionCelebration`` property; dismissing it (tap "Nice"
/// or swipe down) routes through ``dismissSessionCelebration`` so the
/// pending value clears in one place.
private struct SessionCelebrationSheet: View {
    let summary: Catlaser_App_V1_SessionSummary
    let profiles: [Catlaser_App_V1_CatProfile]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            // Drag indicator is supplied by ``presentationDragIndicator``
            // on iOS; the fallback platform mirrors with a manual
            // spacer so the layout reads consistently. The accent
            // pawprint glyph is the "celebration is for your cat"
            // visual cue and stays animation-free per accessibility
            // policy.
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .padding(.top, 12)
                .accessibilityHidden(true)
            Text(HistoryStrings.celebrationTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(bodyCopy)
                .font(.body)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            statGrid
                .padding(.horizontal, 24)
                .padding(.top, 4)
            Spacer(minLength: 0)
            Button {
                Haptics.light.play()
                onDismiss()
            } label: {
                Text(HistoryStrings.celebrationDismissButton)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(SemanticColor.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .accessibilityID(.historyCelebrationDismiss)
            .accessibilityLabel(Text(HistoryStrings.celebrationDismissButton))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SemanticColor.background)
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #endif
    }

    /// Body copy resolved from the cat-id list. Three branches:
    ///
    /// * One named cat → "{name} just played." — the warm common case.
    /// * Multiple named cats → "{names joined} just played." — uses the
    ///   same join helper as the History row so the sheet's wording
    ///   matches what the user sees in the list.
    /// * No resolvable name (unknown cat, profile catalogue not yet
    ///   loaded) → "A cat just played." — fallback that still
    ///   celebrates without falsely naming.
    private var bodyCopy: String {
        let summary = CatProfileFormatter.sessionCatsSummary(
            catIDs: summary.catIds,
            profiles: profiles,
        )
        let knownNames = Set(profiles.map(\.catID))
        let resolvedCount = self.summary.catIds.filter { knownNames.contains($0) }.count
        if resolvedCount == 1 {
            return HistoryStrings.celebrationBodySingleCat(name: summary)
        }
        if resolvedCount > 1 {
            return HistoryStrings.celebrationBodyMultipleCats(joinedNames: summary)
        }
        return HistoryStrings.celebrationBodyUnknownCat
    }

    /// 2×2 grid of stat blocks. Big enough to read across a room —
    /// the sheet is the celebration moment, not a dense data row, so
    /// the values lead the typography. The engagement label uses the
    /// human bucket ("Very playful") rather than the raw percent so
    /// the stat reads on its own; VoiceOver hears the percentage via
    /// the accessibility-only label, matching the row's behaviour.
    private var statGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]
        return LazyVGrid(columns: columns, spacing: 12) {
            statTile(
                icon: "clock",
                value: CatProfileFormatter.playTimeString(secondsTotal: summary.durationSec),
                label: HistoryStrings.celebrationDurationLabel,
                accessibility: nil,
            )
            statTile(
                icon: "bolt.fill",
                value: CatProfileFormatter.engagementLabel(score: summary.engagementScore),
                label: HistoryStrings.celebrationEngagementLabel,
                accessibility: CatProfileFormatter.engagementAccessibilityLabel(
                    score: summary.engagementScore,
                ),
            )
            statTile(
                icon: "circle.grid.cross",
                value: "\(summary.pounceCount)",
                label: HistoryStrings.celebrationPouncesLabel,
                accessibility: nil,
            )
            statTile(
                icon: "fork.knife",
                value: "\(summary.treatsDispensed)",
                label: HistoryStrings.celebrationTreatsLabel,
                accessibility: nil,
            )
        }
    }

    private func statTile(
        icon: String,
        value: String,
        label: String,
        accessibility: String?,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SemanticColor.accent)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SemanticColor.textSecondary)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label), \(accessibility ?? value)"))
    }
}
#endif
