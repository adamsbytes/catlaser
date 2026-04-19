#if canImport(SwiftUI)
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

    public init(viewModel: ScheduleViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            if let error = viewModel.lastActionError {
                actionErrorOverlay(error: error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.lastActionError)
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
                viewModel.discardChanges()
            } label: {
                Text(ScheduleStrings.discardButton)
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(!draftSet.isDirty || isSaving)
            .foregroundStyle(draftSet.isDirty && !isSaving ? Color.white : Color.white.opacity(0.4))
            Spacer()
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .accessibilityLabel(Text(ScheduleStrings.refreshButton))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .foregroundStyle(.white)
            Button {
                Task { await viewModel.save() }
            } label: {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
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
                (draftSet.isDirty && !isSaving ? Color.accentColor : Color.white.opacity(0.12)),
                in: Capsule(),
            )
            .foregroundStyle(.white)
            .disabled(!draftSet.isDirty || isSaving)
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
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(draftSet.entries) { entry in
                        ScheduleEntryRow(
                            entry: entry,
                            onEdit: { editingEntryID = entry.id },
                            onToggleEnabled: { viewModel.toggleEnabled(id: entry.id) },
                        )
                    }
                    Text(ScheduleStrings.quietHoursFootnote)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
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
                .foregroundStyle(.white.opacity(0.55))
                .accessibilityHidden(true)
            Text(ScheduleStrings.emptyTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(ScheduleStrings.emptySubtitle)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(ScheduleStrings.alwaysOnHint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
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
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private func loadingPane(label: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
                .tint(.white)
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
        }
    }

    private func failedPane(error: ScheduleError, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(ScheduleStrings.errorBannerTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(ScheduleStrings.message(for: error))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(ScheduleStrings.retryButton, action: onRetry)
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private func actionErrorOverlay(error: ScheduleError) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(ScheduleStrings.message(for: error))
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Spacer()
                Button(ScheduleStrings.dismissButton) {
                    viewModel.dismissActionError()
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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
                    .foregroundStyle(.white)
                    .opacity(entry.enabled ? 1.0 : 0.5)
                Text(ScheduleStrings.durationLabel(minutes: entry.durationMinutes))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(entry.enabled ? 0.75 : 0.45))
                Text(ScheduleStrings.daysSummary(entry.days))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(entry.enabled ? 0.7 : 0.4))
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { _ in onToggleEnabled() },
            ))
            .labelsHidden()
            .tint(.accentColor)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .accessibilityLabel(Text(ScheduleStrings.entrySheetEditTitle))
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(Color.white.opacity(0.08), in: Circle())
            .foregroundStyle(.white)
        }
        .padding(12)
        .background(Color.white.opacity(entry.enabled ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 16))
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
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(role: .destructive, action: onDelete) {
                        Text(ScheduleStrings.entrySheetDeleteButton)
                    }
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
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(ScheduleStrings.entrySheetSave) { submit() }
                    }
                    #else
                    ToolbarItem {
                        Button(ScheduleStrings.entrySheetCancel, action: onCancel)
                    }
                    ToolbarItem {
                        Button(ScheduleStrings.entrySheetSave) { submit() }
                    }
                    #endif
                }
        }
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
                .foregroundStyle(.primary)
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
