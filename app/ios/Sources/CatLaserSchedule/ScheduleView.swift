#if canImport(SwiftUI)
import CatLaserDesign
import CatLaserProto
import Foundation
import SwiftUI

/// SwiftUI schedule setup screen.
///
/// A list of ``ScheduleEntryDraft`` rows with an "Add time" button,
/// and a Save / Discard toolbar that commits / reverts the draft.
/// Every control binds to a ``ScheduleViewModel`` method or
/// ``@Observable`` property; the view holds no logical state of its
/// own beyond which sheet is open.
/// Dismissible first-run hint banner controller. Host passes one in
/// when the onboarding store says the schedule hint has not been
/// dismissed yet; otherwise the view renders no banner. The
/// ``onDismiss`` closure flips the persistent flag.
///
/// Modelled as a value type over two closures (rather than a binding)
/// so the flag's truth lives in the composition-owned store rather
/// than on a SwiftUI ``@State`` that would reset on view rebuild.
public struct ScheduleFirstRunHint: Sendable {
    /// `true` iff the banner should be rendered on this mount.
    public let isVisible: Bool
    /// Callback fired when the user taps the dismiss button or
    /// successfully commits their first schedule via Save. The host
    /// flips the store flag; subsequent mounts see ``isVisible ==
    /// false`` and no banner renders.
    public let onDismiss: @Sendable () -> Void

    public init(isVisible: Bool, onDismiss: @escaping @Sendable () -> Void) {
        self.isVisible = isVisible
        self.onDismiss = onDismiss
    }
}

public struct ScheduleView: View {
    @Bindable private var viewModel: ScheduleViewModel
    @State private var editingEntryID: String?
    private let firstRunHint: ScheduleFirstRunHint?
    /// Live copy of ``ScheduleFirstRunHint/isVisible``. Starts from
    /// the controller value and drops to `false` on any dismissal
    /// (tap X or first successful save) so the banner vanishes in-
    /// session without waiting for a re-mount. The persistent flag
    /// update happens via ``ScheduleFirstRunHint/onDismiss`` on the
    /// same transition.
    @State private var hintVisible: Bool
    /// Identifies the entry minted by the most recent ``addEntry`` tap
    /// while its sheet is still on-screen. Drives the entry-sheet
    /// title switch ("New playtime" vs "Edit playtime") so a user who
    /// just pressed "+ Add time" reads the correct verb at the top of
    /// the sheet. Cleared when the sheet dismisses (Save, Delete,
    /// Cancel, or interactive swipe-down).
    @State private var recentlyAddedEntryID: String?
    /// Identifies the draft currently pinned to the quick-add sheet —
    /// the simplified mom-friendly add path shown on ``+ Add time``.
    /// Distinct from ``editingEntryID`` so a "More options" tap on
    /// quick-add can dismiss THIS sheet and open the full edit sheet
    /// for the same draft in the same gesture.
    @State private var quickAddID: String?
    /// Drives the destructive confirmation dialog presented when the
    /// user taps the toolbar Cancel button with pending edits in
    /// flight. The dialog itself owns the rollback — the button only
    /// flips this flag.
    @State private var confirmDiscard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var errorFocus: Bool

    public init(
        viewModel: ScheduleViewModel,
        firstRunHint: ScheduleFirstRunHint? = nil,
    ) {
        self.viewModel = viewModel
        self.firstRunHint = firstRunHint
        self._hintVisible = State(initialValue: firstRunHint?.isVisible ?? false)
    }

    public var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            content
            if let error = viewModel.lastActionError {
                actionErrorOverlay(error: error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .accessibilityID(.scheduleRoot)
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
        .onChange(of: isSavingProjection) { oldValue, newValue in
            // isSaving true → false without a fresh error means the
            // SetScheduleRequest landed. Pair the commit haptic the
            // save tap already fired with a success haptic so the
            // user feels the server ack, not just their own tap.
            if oldValue == true, newValue == false, viewModel.lastActionError == nil {
                Haptics.success.play()
                // A successful save implies the user has "got it" —
                // dismiss the first-run hint too so the banner doesn't
                // persist into their second session. No-op if the
                // controller was absent or if the user already
                // dismissed via the X.
                dismissFirstRunHint()
            }
        }
        .task {
            await viewModel.start()
        }
        .sheet(item: editingEntryBinding) { entry in
            ScheduleEntrySheet(
                entry: entry,
                isNewEntry: entry.id == recentlyAddedEntryID,
                onSave: { updated in
                    viewModel.updateEntry(updated)
                    dismissSheet()
                },
                onDelete: {
                    viewModel.deleteEntry(id: entry.id)
                    dismissSheet()
                },
                onCancel: { dismissSheet() },
            )
        }
        .sheet(item: quickAddEntryBinding) { entry in
            QuickAddSheet(
                entry: entry,
                onSave: { updated in
                    viewModel.updateEntry(updated)
                    dismissQuickAdd()
                },
                onCancel: {
                    viewModel.deleteEntry(id: entry.id)
                    dismissQuickAdd()
                },
                onMoreOptions: {
                    // Swap quick-add for the full edit sheet on the same
                    // draft. `quickAddID` clears, `editingEntryID` adopts
                    // the same id; SwiftUI dismisses one sheet and mounts
                    // the other on the next runloop.
                    let id = entry.id
                    quickAddID = nil
                    editingEntryID = id
                    recentlyAddedEntryID = id
                },
            )
        }
        .confirmationDialog(
            ScheduleStrings.discardConfirmTitle,
            isPresented: $confirmDiscard,
            titleVisibility: .visible,
        ) {
            Button(ScheduleStrings.discardConfirmAction, role: .destructive) {
                Haptics.warning.play()
                viewModel.discardChanges()
            }
            Button(ScheduleStrings.cancelButton, role: .cancel) {}
        } message: {
            Text(ScheduleStrings.discardConfirmMessage)
        }
    }

    /// Clear the per-sheet bookkeeping state in lockstep so a Save,
    /// Delete, Cancel, or interactive swipe-down all leave the view in
    /// the same shape — no orphaned ``recentlyAddedEntryID`` that would
    /// flip the next sheet open against an existing row into a "New
    /// window" title.
    private func dismissSheet() {
        editingEntryID = nil
        recentlyAddedEntryID = nil
    }

    /// Clear quick-add bookkeeping. Symmetric with ``dismissSheet`` so
    /// Save / Cancel / interactive swipe-down all leave the view in
    /// the same shape.
    private func dismissQuickAdd() {
        quickAddID = nil
        recentlyAddedEntryID = nil
    }

    /// Projection of the `isSaving` flag so ``onChange`` has a simple
    /// Equatable to watch. Reading the enum directly would require
    /// the whole ``ScheduleViewState`` to be Equatable; the projection
    /// keeps the observer honest about what it cares about.
    private var isSavingProjection: Bool {
        if case let .loaded(_, _, isSaving) = viewModel.state { return isSaving }
        return false
    }

    // MARK: - Root content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            skeletonPane
        case let .loaded(draftSet, isRefreshing, isSaving):
            loadedContent(
                draftSet: draftSet,
                isRefreshing: isRefreshing,
                isSaving: isSaving,
            )
        case let .failed(error):
            failedPane(
                error: error,
                onRetry: { Task { await viewModel.refresh() } },
            )
        }
    }

    private func loadedContent(
        draftSet: ScheduleDraftSet,
        isRefreshing: Bool,
        isSaving: Bool,
    ) -> some View {
        VStack(spacing: 0) {
            if hintVisible {
                firstRunHintBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            toolbar(draftSet: draftSet, isSaving: isSaving)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            entriesList(draftSet: draftSet, isRefreshing: isRefreshing)
            addBar(isSaving: isSaving)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    /// First-run hint banner. Dismissible via a trailing X button and
    /// auto-dismissed on a successful first save. The underlying
    /// persistent flag is flipped via the controller's ``onDismiss``
    /// closure — the local ``hintVisible`` state drops the banner
    /// immediately for a responsive in-session feel.
    @ViewBuilder
    private var firstRunHintBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(SemanticColor.accent)
                .accessibilityDecorativeIcon()
            VStack(alignment: .leading, spacing: 4) {
                Text(ScheduleStrings.firstRunHintTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                Text(ScheduleStrings.firstRunHintBody)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                dismissFirstRunHint()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SemanticColor.textSecondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityID(.onboardingScheduleHintDismiss)
            .accessibilityLabel(Text(ScheduleStrings.firstRunHintDismiss))
        }
        .padding(12)
        .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func dismissFirstRunHint() {
        guard hintVisible, let firstRunHint else { return }
        hintVisible = false
        firstRunHint.onDismiss()
    }

    private func toolbar(
        draftSet: ScheduleDraftSet,
        isSaving: Bool,
    ) -> some View {
        HStack(spacing: 12) {
            // Convention-matching "Cancel" rather than "Discard
            // changes" — the destructive intent is surfaced by the
            // ``confirmDiscard`` dialog the tap presents, not by the
            // button label. Keeps the toolbar paired with "Save" the
            // way every other modal / edit-mode surface in the app
            // does.
            Button {
                confirmDiscard = true
            } label: {
                Text(ScheduleStrings.cancelButton)
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(!draftSet.isDirty || isSaving)
            .foregroundStyle(
                draftSet.isDirty && !isSaving
                    ? SemanticColor.textPrimary
                    : SemanticColor.textTertiary,
            )
            .accessibilityID(.scheduleDiscardButton)
            .accessibilityLabel(Text(ScheduleStrings.cancelButtonAccessibilityLabel))
            Spacer()
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .accessibilityLabel(Text(ScheduleStrings.refreshButton))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .foregroundStyle(SemanticColor.textPrimary)
            .accessibilityID(.scheduleRefreshButton)
            Button {
                Haptics.commit.play()
                Task { await viewModel.save() }
            } label: {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ScheduleStrings.savingLabel)
                    }
                } else {
                    Text(ScheduleStrings.saveButton)
                }
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                (draftSet.isDirty && !isSaving
                    ? SemanticColor.accent
                    : SemanticColor.elevatedFill),
                in: Capsule(),
            )
            .foregroundStyle(
                draftSet.isDirty && !isSaving
                    ? Color.white
                    : SemanticColor.textSecondary,
            )
            .disabled(!draftSet.isDirty || isSaving)
            .accessibilityID(.scheduleSaveButton)
            .accessibilityLabel(Text(ScheduleStrings.saveButton))
        }
    }

    @ViewBuilder
    private func entriesList(
        draftSet: ScheduleDraftSet,
        isRefreshing: Bool,
    ) -> some View {
        if draftSet.entries.isEmpty {
            emptyPane()
        } else {
            // Native ``List`` rather than ``ScrollView`` so the
            // ``.swipeActions`` modifier engages — the iOS-native
            // gesture for row-level actions. Plain style + cleared
            // row chrome preserves the previous card-on-background
            // look; ``scrollContentBackground(.hidden)`` lets the
            // parent's ``SemanticColor.background`` show through.
            List {
                ForEach(draftSet.entries) { entry in
                    ScheduleEntryRow(
                        entry: entry,
                        isSaving: isSavingProjection,
                        onEdit: { editingEntryID = entry.id },
                        onToggleEnabled: {
                            // Gate the selection haptic on the VM's
                            // acceptance of the tap. ``@MainActor``
                            // VM hop is a few ms, so the haptic still
                            // feels instant, but it never fires for
                            // a tap the VM dropped — which can happen
                            // when a rapid second tap slips through
                            // the single-frame window before SwiftUI
                            // re-renders the Toggle as disabled on
                            // the prior tap's in-flight save. The
                            // error haptic on a wire-failure path is
                            // fired from the ``lastActionError``
                            // observer on the screen root, so a
                            // rejected commit still surfaces.
                            Task {
                                if await viewModel.toggleEnabled(id: entry.id) {
                                    Haptics.selection.play()
                                }
                            }
                        },
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            // Local-draft mutation; no wire traffic
                            // until the user hits Save. The warning
                            // haptic acknowledges the destructive
                            // commit at the gesture site.
                            Haptics.warning.play()
                            viewModel.deleteEntry(id: entry.id)
                        } label: {
                            Label(
                                ScheduleStrings.entrySheetDeleteButton,
                                systemImage: "trash",
                            )
                        }
                        Button {
                            editingEntryID = entry.id
                        } label: {
                            Label(
                                ScheduleStrings.entrySheetEditTitle,
                                systemImage: "pencil",
                            )
                        }
                        .tint(SemanticColor.accent)
                    }
                }
                Text(ScheduleStrings.quietHoursFootnote)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(SemanticColor.background)
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(ScheduleStrings.loadingLabel))
                        .padding(.top, 8)
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }

    private func emptyPane() -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(SemanticColor.textTertiary)
                .accessibilityDecorativeIcon()
            Text(ScheduleStrings.emptyTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(ScheduleStrings.emptySubtitle)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(ScheduleStrings.alwaysOnHint)
                .font(.caption)
                .foregroundStyle(SemanticColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func addBar(isSaving: Bool) -> some View {
        Button {
            if let newID = viewModel.addEntry() {
                // Track the freshly-minted id so the entry sheet
                // titles itself "New playtime" rather than "Edit
                // playtime" until the user dismisses it, and so a
                // "More options" tap can transfer the same id to the
                // full edit sheet.
                recentlyAddedEntryID = newID
                quickAddID = newID
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .accessibilityHidden(true)
                Text(ScheduleStrings.addButton)
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(SemanticColor.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityID(.scheduleAddButton)
        .accessibilityLabel(Text(ScheduleStrings.addButton))
    }

    /// Skeleton placeholder shown during the initial schedule fetch.
    /// Mirrors the ``ScheduleEntryRow`` layout (time + duration +
    /// days block on the leading edge, a toggle-shaped pill and an
    /// edit-shaped round on the trailing edge) so the real rows land
    /// in the same slots when the load completes. SwiftUI's
    /// ``.redacted(reason: .placeholder)`` paints the neutral wash;
    /// a single combined accessibility element announces the load
    /// once instead of five times.
    ///
    /// A row count of five matches what a typical schedule shows on
    /// a phone without pushing below the safe area on a Pro Max —
    /// aligned with ``HistoryView`` using six rows for its denser
    /// list layout.
    private var skeletonPane: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0 ..< 5, id: \.self) { _ in
                    ScheduleEntrySkeletonRow()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .redacted(reason: .placeholder)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(ScheduleStrings.skeletonAccessibility))
            .accessibilityAddTraits(.updatesFrequently)
        }
        .scrollDisabled(true)
    }

    private func failedPane(error: ScheduleError, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(SemanticColor.warning)
                .accessibilityDecorativeIcon()
            Text(ScheduleStrings.errorBannerTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(ScheduleStrings.message(for: error))
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(ScheduleStrings.retryButton, action: onRetry)
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(SemanticColor.accent, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityID(.scheduleRetry)
                .accessibilityLabel(Text(ScheduleStrings.retryButton))
            Spacer()
        }
    }

    private func actionErrorOverlay(error: ScheduleError) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(SemanticColor.warning)
                    .accessibilityHidden(true)
                Text(ScheduleStrings.message(for: error))
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textPrimary)
                    .lineLimit(3)
                    .accessibilityFocused($errorFocus)
                Spacer()
                Button(ScheduleStrings.dismissButton) {
                    viewModel.dismissActionError()
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityID(.scheduleDismissError)
                .accessibilityLabel(Text(ScheduleStrings.dismissButton))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Sheet binding helper

    /// Bridges ``editingEntryID`` + the current draft set into a
    /// ``Binding<ScheduleEntryDraft?>`` the ``.sheet(item:)``
    /// modifier can consume. Resolves the id against the live draft
    /// so an external mutation (a concurrent refresh landing while
    /// the sheet is open) re-reads the latest draft rather than
    /// stale snapshot the sheet was originally built with.
    private var editingEntryBinding: Binding<ScheduleEntryDraft?> {
        Binding(
            get: {
                guard let id = editingEntryID,
                      case let .loaded(draftSet, _, _) = viewModel.state
                else {
                    return nil
                }
                return draftSet.entries.first { $0.id == id }
            },
            set: { newValue in
                // Interactive swipe-down lands here with `nil`. Route
                // it through ``dismissSheet`` so the per-sheet
                // bookkeeping (``recentlyAddedEntryID``) is cleared in
                // the same way Save/Delete/Cancel clear it. A non-nil
                // write is structurally unreachable for a binding we
                // own (SwiftUI only writes nil for dismissal); fall
                // through to ``editingEntryID`` for that case.
                if newValue == nil {
                    dismissSheet()
                } else {
                    editingEntryID = newValue?.id
                }
            },
        )
    }

    /// Mirror of ``editingEntryBinding`` for the quick-add sheet. The
    /// quick-add sheet and the full edit sheet never present at the
    /// same time — the "More options" hand-off clears
    /// ``quickAddID`` before it sets ``editingEntryID``, so SwiftUI
    /// dismisses one before mounting the other.
    private var quickAddEntryBinding: Binding<ScheduleEntryDraft?> {
        Binding(
            get: {
                guard let id = quickAddID,
                      case let .loaded(draftSet, _, _) = viewModel.state
                else {
                    return nil
                }
                return draftSet.entries.first { $0.id == id }
            },
            set: { newValue in
                if newValue == nil {
                    // Interactive swipe-down. Treat as cancel: pop the
                    // freshly-minted draft so the user doesn't silently
                    // accumulate empty rows. `deleteEntry` is a no-op
                    // if the id doesn't exist, so a racing delete from
                    // another path is safe.
                    if let id = quickAddID {
                        viewModel.deleteEntry(id: id)
                    }
                    dismissQuickAdd()
                } else {
                    quickAddID = newValue?.id
                }
            },
        )
    }
}

// MARK: - Row

private struct ScheduleEntryRow: View {
    let entry: ScheduleEntryDraft
    let isSaving: Bool
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Single-sentence summary — collapses the former three-line
            // stack so mom parses the row as one thought rather than
            // three disconnected data points. Power users lose no
            // information: every field is still rendered, just in a
            // natural-language form. Tap-through to the full edit sheet
            // remains the primary interaction.
            Text(rowSummary)
                .font(.body.weight(.semibold))
                .foregroundStyle(
                    entry.enabled
                        ? SemanticColor.textPrimary
                        : SemanticColor.textTertiary,
                )
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(rowSummary))
            Spacer()
            // Disable the toggle while a save is in flight so a rapid
            // second tap cannot race the first commit. The VM's own
            // guard is authoritative; disabling here suppresses the
            // SwiftUI "wobble" that would otherwise appear when a
            // second set-closure call gets silently dropped by the VM
            // while the binding's get-closure still returns the old
            // value.
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { _ in onToggleEnabled() },
            ))
            .labelsHidden()
            .tint(SemanticColor.accent)
            .disabled(isSaving)
            .accessibilityID(.scheduleEntryToggle)
            .accessibilityLabel(Text("\(ScheduleStrings.entrySheetEnabledLabel), \(rowSummary)"))
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .accessibilityLabel(Text("\(ScheduleStrings.entrySheetEditTitle), \(rowSummary)"))
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(SemanticColor.elevatedFill, in: Circle())
            .foregroundStyle(SemanticColor.textPrimary)
            .accessibilityID(.scheduleEntryEdit)
            .disabled(isSaving)
        }
        .padding(12)
        .background(
            SemanticColor.groupedBackground.opacity(entry.enabled ? 1.0 : 0.7),
            in: RoundedRectangle(cornerRadius: 16),
        )
        .accessibilityID(.scheduleEntryRow)
        // No outer ``.accessibilityElement(children: .combine)``: a
        // VoiceOver user must be able to focus and activate the toggle
        // and the edit button independently, the way they would on
        // any native list row.
    }

    /// Single-sentence summary rendered both on the row body and as
    /// the VoiceOver label. Example: "Every weekday at 8:00 AM for
    /// 15 minutes". The row-body text and the VoiceOver label point
    /// at the same source so what a sighted user reads matches what
    /// a screen-reader user hears — no hidden trailing ", 15m" that
    /// visually renders differently from the spoken form.
    private var rowSummary: String {
        ScheduleStrings.summarySentence(
            days: entry.days,
            startMinute: entry.startMinute,
            durationMinutes: entry.durationMinutes,
        )
    }
}

// MARK: - Edit sheet

private struct ScheduleEntrySheet: View {
    let entry: ScheduleEntryDraft
    /// True iff the entry was minted by the most-recent ``addEntry``
    /// tap. Selects the sheet title between ``entrySheetAddTitle``
    /// ("New playtime") and ``entrySheetEditTitle`` ("Edit playtime")
    /// — a user who just pressed "+ Add time" must read the correct
    /// verb at the top of the sheet.
    let isNewEntry: Bool
    let onSave: (ScheduleEntryDraft) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var draft: ScheduleEntryDraft
    @State private var validationFailure: ScheduleValidation.Failure?
    /// Drives the destructive confirmation dialog presented when the
    /// user taps the in-sheet Delete button. Matches the pattern every
    /// other destructive surface in the app uses (cat delete, unpair,
    /// sign out, delete account, toolbar Discard).
    @State private var confirmDelete = false

    init(
        entry: ScheduleEntryDraft,
        isNewEntry: Bool,
        onSave: @escaping (ScheduleEntryDraft) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void,
    ) {
        self.entry = entry
        self.isNewEntry = isNewEntry
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self._draft = State(initialValue: entry)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(ScheduleStrings.entrySheetStartLabel)) {
                    startMinutePicker
                }
                Section(header: Text(ScheduleStrings.entrySheetDurationLabel)) {
                    durationStepper
                }
                Section(header: Text(ScheduleStrings.entrySheetDaysLabel)) {
                    daysToggles
                }
                Section {
                    Toggle(ScheduleStrings.entrySheetEnabledLabel, isOn: $draft.enabled)
                }
                if let validationFailure {
                    Section {
                        Text(ScheduleStrings.validationMessage(for: validationFailure))
                            .font(.footnote)
                            .foregroundStyle(SemanticColor.destructive)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text(ScheduleStrings.entrySheetDeleteButton)
                    }
                    .accessibilityID(.scheduleEntrySheetDelete)
                }
            }
            .confirmationDialog(
                ScheduleStrings.entrySheetDeleteConfirmTitle,
                isPresented: $confirmDelete,
                titleVisibility: .visible,
            ) {
                Button(ScheduleStrings.entrySheetDeleteConfirmAction, role: .destructive) {
                    Haptics.warning.play()
                    onDelete()
                }
                Button(ScheduleStrings.entrySheetCancel, role: .cancel) {}
            } message: {
                Text(ScheduleStrings.entrySheetDeleteConfirmMessage)
            }
            .navigationTitle(
                isNewEntry
                    ? ScheduleStrings.entrySheetAddTitle
                    : ScheduleStrings.entrySheetEditTitle,
            )
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button(ScheduleStrings.entrySheetCancel, action: onCancel)
                            .accessibilityID(.scheduleEntrySheetCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(ScheduleStrings.entrySheetSave) { submit() }
                            .accessibilityID(.scheduleEntrySheetSave)
                    }
                    #else
                    ToolbarItem {
                        Button(ScheduleStrings.entrySheetCancel, action: onCancel)
                            .accessibilityID(.scheduleEntrySheetCancel)
                    }
                    ToolbarItem {
                        Button(ScheduleStrings.entrySheetSave) { submit() }
                            .accessibilityID(.scheduleEntrySheetSave)
                    }
                    #endif
                }
        }
        // Entry sheet has a time picker, a stepper, seven day toggles,
        // an enabled switch, an optional validation row, and a
        // destructive Delete button — every layout pushes past
        // ``.medium`` on every iPhone, so opening at ``.medium`` would
        // show a clipped form and force the user to drag up before
        // they could reach the bottom controls. ``.large`` only.
        // The drag indicator stays visible so swipe-down still reads
        // as a dismiss affordance.
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var startMinutePicker: some View {
        let components = DateComponents(
            hour: draft.startMinute / 60,
            minute: draft.startMinute % 60,
        )
        let calendar = Calendar.current
        let initial = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        return DatePicker(
            ScheduleStrings.entrySheetStartLabel,
            selection: Binding(
                get: { initial },
                set: { newValue in
                    let parts = calendar.dateComponents([.hour, .minute], from: newValue)
                    let total = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    draft.startMinute = max(
                        ScheduleValidation.minStartMinute,
                        min(total, ScheduleValidation.maxStartMinute),
                    )
                },
            ),
            displayedComponents: .hourAndMinute,
        )
        .labelsHidden()
    }

    private var durationStepper: some View {
        HStack {
            Text(ScheduleStrings.durationLabel(minutes: draft.durationMinutes))
                .foregroundStyle(SemanticColor.textPrimary)
            Spacer()
            Stepper(
                "",
                value: $draft.durationMinutes,
                in: ScheduleValidation.minDurationMinutes ... ScheduleValidation.maxDurationMinutes,
                step: 5,
            )
            .labelsHidden()
        }
    }

    private var daysToggles: some View {
        let order: [Catlaser_App_V1_DayOfWeek] = [
            .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
        ]
        return ForEach(order, id: \.rawValue) { day in
            Toggle(
                ScheduleStrings.fullDayLabel(day),
                isOn: Binding(
                    get: { draft.days.contains(day) },
                    set: { isOn in
                        if isOn {
                            draft.days.insert(day)
                        } else {
                            draft.days.remove(day)
                        }
                    },
                ),
            )
        }
    }

    private func submit() {
        if let failure = ScheduleValidation.validate(draft) {
            validationFailure = failure
            return
        }
        validationFailure = nil
        onSave(draft)
    }
}

// MARK: - Skeleton placeholder row

/// Schedule-row skeleton used during the initial load. Shape matches
/// ``ScheduleEntryRow`` — title, duration line, days line on the
/// leading edge; a toggle-shaped capsule and an edit-shaped round on
/// the trailing edge — so the real rows arrive without a visible
/// reflow. Painted in a single neutral fill; the parent applies
/// ``.redacted(reason: .placeholder)`` so SwiftUI handles the
/// placeholder wash.
private struct ScheduleEntrySkeletonRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 96, height: 20)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 72, height: 10)
                RoundedRectangle(cornerRadius: 4)
                    .fill(SemanticColor.elevatedFill)
                    .frame(width: 150, height: 10)
            }
            Spacer()
            Capsule()
                .fill(SemanticColor.elevatedFill)
                .frame(width: 51, height: 31)
            Circle()
                .fill(SemanticColor.elevatedFill)
                .frame(width: 36, height: 36)
        }
        .padding(12)
        .background(
            SemanticColor.groupedBackground,
            in: RoundedRectangle(cornerRadius: 16),
        )
    }
}

// MARK: - Quick-add sheet

/// Simplified add-time sheet shown on the first tap of "+ Add time".
///
/// A single time picker plus a caption that names the defaults (15
/// minutes, every day). "Save" commits the draft via the parent's
/// ``onSave`` callback with those defaults baked in; "More options"
/// hands off to the full ``ScheduleEntrySheet`` for the same draft so
/// power users can customise without a detour. Mom sees one field.
///
/// This view intentionally does NOT mutate the underlying
/// ``ScheduleViewModel`` — it speaks only to the parent via the three
/// callbacks, mirroring how the full edit sheet stays storage-agnostic.
private struct QuickAddSheet: View {
    let entry: ScheduleEntryDraft
    let onSave: (ScheduleEntryDraft) -> Void
    let onCancel: () -> Void
    let onMoreOptions: () -> Void

    @State private var draft: ScheduleEntryDraft

    init(
        entry: ScheduleEntryDraft,
        onSave: @escaping (ScheduleEntryDraft) -> Void,
        onCancel: @escaping () -> Void,
        onMoreOptions: @escaping () -> Void,
    ) {
        self.entry = entry
        self.onSave = onSave
        self.onCancel = onCancel
        self.onMoreOptions = onMoreOptions
        self._draft = State(initialValue: entry)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                timePicker
                Text(ScheduleStrings.quickAddCaption(durationMinutes: draft.durationMinutes))
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Spacer()

                Button {
                    onMoreOptions()
                } label: {
                    Text(ScheduleStrings.quickAddMoreOptionsButton)
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(SemanticColor.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .navigationTitle(ScheduleStrings.quickAddTitle)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button(ScheduleStrings.quickAddCancelButton, action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(ScheduleStrings.quickAddSaveButton) {
                            Haptics.commit.play()
                            onSave(draft)
                        }
                    }
                    #else
                    ToolbarItem {
                        Button(ScheduleStrings.quickAddCancelButton, action: onCancel)
                    }
                    ToolbarItem {
                        Button(ScheduleStrings.quickAddSaveButton) {
                            onSave(draft)
                        }
                    }
                    #endif
                }
        }
        // A time-only surface needs minimal chrome; `.medium` fits the
        // picker + caption + More-options tap target on every shipping
        // phone size without scrolling. Users who need the full
        // 7-day / duration / enabled surface tap "More options".
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var timePicker: some View {
        let components = DateComponents(
            hour: draft.startMinute / 60,
            minute: draft.startMinute % 60,
        )
        let calendar = Calendar.current
        let initial = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        return DatePicker(
            ScheduleStrings.entrySheetStartLabel,
            selection: Binding(
                get: { initial },
                set: { newValue in
                    let parts = calendar.dateComponents([.hour, .minute], from: newValue)
                    let total = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    draft.startMinute = max(
                        ScheduleValidation.minStartMinute,
                        min(total, ScheduleValidation.maxStartMinute),
                    )
                },
            ),
            displayedComponents: .hourAndMinute,
        )
        #if os(iOS)
        .datePickerStyle(.wheel)
        #endif
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}
#endif
