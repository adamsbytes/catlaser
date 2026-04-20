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
                )
                statBlock(
                    icon: "bolt.fill",
                    label: String(format: "%.0f%%", session.engagementScore * 100),
                )
                statBlock(
                    icon: "circle.grid.cross",
                    label: "\(session.pounceCount)",
                )
                statBlock(
                    icon: "fork.knife",
                    label: "\(session.treatsDispensed)",
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

    private func statBlock(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(label)
        }
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
#endif
