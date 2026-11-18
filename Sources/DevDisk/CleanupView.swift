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
                Text("\(model.filteredSuggestions.count) suggestions")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if model.filteredSuggestions.isEmpty && model.phase == .scanning {
                ContentUnavailableView("Scanning", systemImage: "sparkles", description: Text("Known caches show up here as soon as they are measured. You can delete a card while the scan continues."))
            } else if model.rootPath == nil {
                ContentUnavailableView("No scan yet", systemImage: "sparkles", description: Text("Scan your home folder to find developer caches."))
            } else if model.filteredSuggestions.isEmpty {
                ContentUnavailableView(
                    "Nothing matched",
                    systemImage: "checkmark.circle",
                    description: Text("No cleanup rules matched this folder above the size threshold. Scan your home folder if you chose a smaller directory.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(CleanupReport.groups(from: model.filteredSuggestions)) { group in
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
                                    CleanupCard(model: model, suggestion: suggestion)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct CleanupCard: View {
    var model: AppModel
    var suggestion: CleanupSuggestion
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
                    Text(suggestion.estimateIsUpperBound ? "Up to \(ByteFormat.string(suggestion.size))" : ByteFormat.string(suggestion.size))
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
                if suggestion.items.contains(where: { $0.projectName != nil }) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(suggestion.items.prefix(8), id: \.path) { item in
                            HStack {
                                Text(item.projectName ?? item.path)
                                    .lineLimit(1)
                                if let date = item.lastModified {
                                    Text(date.formatted(date: .abbreviated, time: .omitted))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ByteFormat.string(item.bytes))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        if suggestion.items.count > 8 {
                            Text("\(suggestion.items.count - 8) more projects are listed in the confirmation.")
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
                        if suggestion.paths.count > 40 {
                            Text("\(suggestion.paths.count - 40) more paths are listed in the confirmation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(suggestion.paths.count) \(suggestion.paths.count == 1 ? "path" : "paths")")
                        .font(.caption)
                }
                HStack {
                    Button("Preview") { model.ask(suggestion, dryRun: true) }
                    if !model.previewOnly {
                        Button(primaryTitle) { model.ask(suggestion, dryRun: false) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(14)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var primaryTitle: String {
        switch suggestion.effect {
        case .removePermanently: model.movesToTrash ? "Move to Trash" : "Delete"
        case .moveToTrash: "Move to Trash"
        case .emptyTrash: "Empty Trash"
        case .command, .commandForEach: "Run command"
        }
    }
}
#endif
