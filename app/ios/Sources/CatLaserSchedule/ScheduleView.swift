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
public struct ScheduleView: View {
    @Bindable private var viewModel: ScheduleViewModel
    @State private var editingEntryID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var errorFocus: Bool

    public init(viewModel: ScheduleViewModel) {
        self.viewModel = viewModel
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
            }
        }
        .task {
            await viewModel.start()
        }
        .sheet(item: editingEntryBinding) { entry in
            ScheduleEntrySheet(
                entry: entry,
                onSave: { updated in
                    viewModel.updateEntry(updated)
                    editingEntryID = nil
                },
                onDelete: {
                    viewModel.deleteEntry(id: entry.id)
                    editingEntryID = nil
                },
                onCancel: { editingEntryID = nil },
            )
        }
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
            loadingPane(label: ScheduleStrings.loadingLabel)
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
            toolbar(draftSet: draftSet, isSaving: isSaving)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            entriesList(draftSet: draftSet, isRefreshing: isRefreshing)
            addBar(isSaving: isSaving)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private func toolbar(
        draftSet: ScheduleDraftSet,
        isSaving: Bool,
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                Haptics.warning.play()
                viewModel.discardChanges()
            } label: {
                Text(ScheduleStrings.discardButton)
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
            .accessibilityLabel(Text(ScheduleStrings.discardButton))
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
                        onEdit: { editingEntryID = entry.id },
                        onToggleEnabled: { viewModel.toggleEnabled(id: entry.id) },
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
                editingEntryID = newID
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
                editingEntryID = newValue?.id
            },
        )
    }
}

// MARK: - Row

private struct ScheduleEntryRow: View {
    let entry: ScheduleEntryDraft
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ScheduleStrings.timeOfDay(minute: entry.startMinute))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SemanticColor.textPrimary)
                    .opacity(entry.enabled ? 1.0 : 0.5)
                Text(ScheduleStrings.durationLabel(minutes: entry.durationMinutes))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        entry.enabled
                            ? SemanticColor.textSecondary
                            : SemanticColor.textTertiary,
                    )
                Text(ScheduleStrings.daysSummary(entry.days))
                    .font(.caption)
                    .foregroundStyle(
                        entry.enabled
                            ? SemanticColor.textSecondary
                            : SemanticColor.textTertiary,
                    )
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { _ in onToggleEnabled() },
            ))
            .labelsHidden()
            .tint(SemanticColor.accent)
            .accessibilityID(.scheduleEntryToggle)
            .accessibilityLabel(Text(ScheduleStrings.entrySheetEnabledLabel))
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .accessibilityLabel(Text(ScheduleStrings.entrySheetEditTitle))
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(SemanticColor.elevatedFill, in: Circle())
            .foregroundStyle(SemanticColor.textPrimary)
            .accessibilityID(.scheduleEntryEdit)
        }
        .padding(12)
        .background(
            SemanticColor.groupedBackground.opacity(entry.enabled ? 1.0 : 0.7),
            in: RoundedRectangle(cornerRadius: 16),
        )
        .accessibilityID(.scheduleEntryRow)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Edit sheet

private struct ScheduleEntrySheet: View {
    let entry: ScheduleEntryDraft
    let onSave: (ScheduleEntryDraft) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var draft: ScheduleEntryDraft
    @State private var validationFailure: ScheduleValidation.Failure?

    init(
        entry: ScheduleEntryDraft,
        onSave: @escaping (ScheduleEntryDraft) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void,
    ) {
        self.entry = entry
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
                        Haptics.warning.play()
                        onDelete()
                    } label: {
                        Text(ScheduleStrings.entrySheetDeleteButton)
                    }
                    .accessibilityID(.scheduleEntrySheetDelete)
                }
            }
            .navigationTitle(ScheduleStrings.entrySheetEditTitle)
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
        // and an enabled switch. ``.large`` is the default because all
        // those rows together push past ``.medium``; ``.medium`` is
        // still offered so a user editing one specific field can
        // collapse the sheet without dismissing.
        #if os(iOS)
        .presentationDetents([.medium, .large])
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
#endif
