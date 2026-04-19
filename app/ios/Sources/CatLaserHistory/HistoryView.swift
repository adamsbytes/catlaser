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
            set: { _ in /* dismissal routes through VM */ },
        )) { prompt in
            NameNewCatSheet(
                prompt: prompt,
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
            loadingPane(label: HistoryStrings.catListLoadingLabel)
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
        ScrollView {
            VStack(spacing: 12) {
                ForEach(profiles, id: \.catID) { profile in
                    CatProfileRow(
                        profile: profile,
                        onEdit: { editingProfile = profile },
                        onDelete: { pendingDeletion = profile },
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
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
            loadingPane(label: HistoryStrings.sessionsLoadingLabel)
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
        return ScrollView {
            VStack(spacing: 12) {
                ForEach(sessions, id: \.sessionID) { session in
                    PlaySessionRow(session: session, profiles: profiles)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
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

    private func loadingPane(label: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
                .accessibilityLabel(Text(label))
            Text(label)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
        }
        .accessibilityElement(children: .combine)
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
    let onDelete: () -> Void

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
            VStack(spacing: 8) {
                Button(HistoryStrings.catRowEditButton, action: onEdit)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(SemanticColor.accent.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityID(.historyCatEdit)
                    .accessibilityLabel(
                        Text("\(HistoryStrings.catRowEditButton) \(profile.name)"),
                    )
                Button(HistoryStrings.catRowDeleteButton, role: .destructive, action: onDelete)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(SemanticColor.elevatedFill, in: Capsule())
                    .foregroundStyle(SemanticColor.destructive)
                    .accessibilityID(.historyCatDelete)
                    .accessibilityLabel(
                        Text("\(HistoryStrings.catRowDeleteButton) \(profile.name)"),
                    )
            }
        }
        .padding(12)
        .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityID(.historyCatRow)
        .accessibilityElement(children: .combine)
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
            .navigationTitle(HistoryStrings.namingSheetTitle)
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
