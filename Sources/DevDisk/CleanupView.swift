#if os(macOS)
import SwiftUI
import DevDiskCore

struct CleanupScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Stepper(value: Binding(
                    get: { model.staleAfterDays },
                    set: { model.setStaleDays($0) }
                ), in: 0...3650) {
                    Text("Projects untouched for \(model.staleAfterDays)+ days")
                }
                .fixedSize()
                Picker("Safety", selection: $model.safetyFilter) {
                    ForEach(SafetyFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                Toggle("Preview only", isOn: $model.previewOnly)
                Toggle("Move to Trash", isOn: $model.movesToTrash)
                    .help("Off deletes permanently. On moves the files to Trash instead.")
                Spacer()
                SafeBatchControl(model: model)
                Text("\(model.displayedCount) suggestions")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if model.batchSession.bannerVisible {
                SafeBatchBanner(model: model)
            }
            if model.displayedCount == 0 && model.phase == .scanning {
                ContentUnavailableView("Scanning", systemImage: "sparkles", description: Text("Known caches show up here as soon as they are measured. You can delete a card while the scan continues."))
            } else if model.rootPath == nil {
                ContentUnavailableView("No scan yet", systemImage: "sparkles", description: Text("Scan your home folder to find developer caches."))
            } else if model.displayedCount == 0 {
                ContentUnavailableView(
                    "Nothing matched",
                    systemImage: "checkmark.circle",
                    description: Text("No cleanup rules matched this folder above the size threshold. Scan your home folder if you chose a smaller directory.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(model.displayedGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(group.ecosystem.title).font(.title3.weight(.semibold))
                                    Text(group.ecosystem.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(ByteFormat.string(group.totalBytes))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(group.suggestions) { suggestion in
                                    CleanupCard(
                                        suggestion: suggestion,
                                        display: model.display(for: suggestion.id),
                                        progress: model.progressStore(for: suggestion.id),
                                        previewOnly: model.previewOnly,
                                        movesToTrash: model.movesToTrash,
                                        onPreview: { model.ask(suggestion, dryRun: true) },
                                        onRun: { model.ask(suggestion, dryRun: false) },
                                        onCancel: { model.cancelRow(suggestion.id) }
                                    )
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(isPresented: $model.showingSafeBatch) {
            SafeBatchSheet(model: model)
        }
        .sheet(isPresented: $model.showingBatchSummary) {
            SafeBatchSummarySheet(model: model)
        }
    }
}

private struct CleanupCard: View {
    var suggestion: CleanupSuggestion
    var display: CardDisplay
    var progress: CardProgress
    var previewOnly: Bool
    var movesToTrash: Bool
    var onPreview: () -> Void
    var onRun: () -> Void
    var onCancel: () -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(DevDiskTheme.safety(suggestion.safety))
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(suggestion.headline)
                        .font(.headline)
                    Spacer()
                    Text(display.sizeText)
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                HStack {
                    SafetyBadge(level: suggestion.safety)
                    Text(suggestion.safety.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !suggestion.countsTowardEstimate {
                        Text("Not in the estimate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(suggestion.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(suggestion.actionDescription)
                    .font(.callout.monospaced())
                if !display.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(display.lines, id: \.self) { line in
                            Text(line)
                                .font(.callout)
                                .lineLimit(1)
                        }
                        if suggestion.items.count > display.lines.count {
                            Text("\(suggestion.items.count - display.lines.count) more projects are listed in the confirmation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestion.paths.prefix(40), id: \.self) { path in
                            Text(path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(display.pathLabel)
                        .font(.caption)
                }
                HStack(spacing: 10) {
                    if let activity = progress.activity {
                        switch activity {
                        case .running:
                            ProgressView()
                                .controlSize(.small)
                            Text(activity.caption)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Button(action: onCancel) {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .help("Stop. What is already removed stays removed.")
                        case .finished(_, let success, _):
                            Text(activity.caption)
                                .font(.callout)
                                .foregroundStyle(success ? DevDiskTheme.reclaim : Color.red)
                                .lineLimit(3)
                            if !success {
                                Spacer()
                                actionButtons
                            }
                        }
                    } else {
                        actionButtons
                    }
                }
            }
            .padding(14)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Preview", action: onPreview)
        if !previewOnly {
            Button(primaryTitle, action: onRun)
                .buttonStyle(.borderedProminent)
        }
    }

    private var primaryTitle: String {
        switch suggestion.effect {
        case .removePermanently: movesToTrash ? "Move to Trash" : "Delete"
        case .moveToTrash: "Move to Trash"
        case .emptyTrash: "Empty Trash"
        case .command, .commandForEach: "Run command"
        }
    }
}

private struct SafeBatchControl: View {
    var model: AppModel

    var body: some View {
        if model.batchSession.running {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(model.batchProgressLabel())
                    .font(.callout)
                    .lineLimit(1)
                Button {
                    model.cancelSafeBatch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop the remaining Safe items")
            }
        } else if !model.safeBatchSuggestions.isEmpty {
            Button(model.safeBatchTitle) { model.openSafeBatch() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct SafeBatchBanner: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(DevDiskTheme.reclaim)
            Text(model.batchBannerText)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Details") { model.showBatchSummary() }
            Button {
                model.dismissBatchBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DevDiskTheme.reclaim.opacity(0.12))
    }
}

private struct SafeBatchSummarySheet: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safe cleanup finished")
                .font(.title3.weight(.semibold))
            Text(model.batchBannerText)
                .font(.title3.monospacedDigit().weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.safeBatchLines) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: line.success ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(line.success ? DevDiskTheme.reclaim : Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).lineLimit(1)
                                Text(line.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 420)
            HStack {
                Spacer()
                Button("Done") { model.showingBatchSummary = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

private struct SafeBatchSheet: View {
    @Bindable var model: AppModel
    @State private var excluded: Set<String> = []

    private var included: [CleanupSuggestion] {
        model.safeBatchSuggestions.filter { !excluded.contains($0.id) }
    }

    private var includedBytes: UInt64 {
        included.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                Text(model.movesToTrash ? "Move all Safe to Trash?" : (model.previewOnly ? "Preview all Safe?" : "Delete all Safe?"))
                    .font(.title3.weight(.semibold))
                Text("Only Safe items. Review suggestions stay untouched. Uncheck anything you want to keep.")
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(includedBytes))
                    .font(.title2.monospacedDigit().weight(.semibold))
                Text("\(included.count) of \(model.safeBatchSuggestions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.safeBatchSuggestions) { suggestion in
                            Toggle(isOn: Binding(
                                get: { !excluded.contains(suggestion.id) },
                                set: { included in
                                    if included { excluded.remove(suggestion.id) }
                                    else { excluded.insert(suggestion.id) }
                                }
                            )) {
                                HStack {
                                    Text(suggestion.headline).lineLimit(1)
                                    Spacer()
                                    Text(ByteFormat.string(suggestion.size))
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 420)
                HStack {
                    Button("Cancel") { model.showingSafeBatch = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(model.previewOnly ? "Preview" : "Confirm") {
                        model.runSafeBatch(excluding: excluded)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(included.isEmpty)
                }
        }
        .padding(20)
        .frame(width: 640)
    }
}
#endif
