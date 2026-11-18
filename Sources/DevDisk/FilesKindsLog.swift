#if os(macOS)
import SwiftUI
import DevDiskCore

struct FilesScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.tree?.stats.fileCount.formatted() ?? "0") files")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(OutlineOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if let root = model.sortedRoot {
                List(selection: $model.selectedID) {
                    OutlineGroup([root], children: \.outlineChildren) { node in
                        HStack(spacing: 8) {
                            Circle().fill(node.kind.color).frame(width: 8, height: 8)
                            Text(node.name).lineLimit(1)
                            if node.countsAsDuplicateHardLink {
                                Text("hard link").font(.caption2).foregroundStyle(.secondary)
                            }
                            if node.isSymlink {
                                Text("link").font(.caption2).foregroundStyle(.secondary)
                            }
                            if node.isOtherVolume {
                                Text("other volume").font(.caption2).foregroundStyle(.secondary)
                            }
                            if node.errorMessage != nil {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(node.kind.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 88, alignment: .leading)
                            Text(ByteFormat.string(node.allocatedSize))
                                .font(.body.monospacedDigit())
                                .frame(width: 92, alignment: .trailing)
                        }
                        .tag(node.id)
                        .contextMenu {
                            Button("Reveal in Finder") { MacActions.reveal(node.path) }
                            if node.isDirectory {
                                Button("Show on map") {
                                    model.zoomPath = node.path
                                    model.section = .map
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No scan yet", systemImage: "list.bullet.indent", description: Text("Scan a folder to browse it by size."))
            }
        }
    }
}

struct KindsScreen: View {
    var model: AppModel

    var body: some View {
        if let root = model.tree?.root {
            let kinds = UsageSummary.kinds(in: root)
            let extensions = UsageSummary.extensions(in: root)
            let maxKind = kinds.map(\.allocatedSize).max() ?? 1
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("By kind").font(.headline)
                    ForEach(kinds) { total in
                        bar(title: total.kind.label, color: total.kind.color, size: total.allocatedSize, count: total.count, max: maxKind)
                    }
                    Text("By extension").font(.headline).padding(.top, 8)
                    ForEach(extensions.prefix(16)) { item in
                        HStack {
                            Text(item.extensionName).frame(width: 80, alignment: .leading)
                            Text("\(item.count.formatted())").foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            Spacer()
                            Text(ByteFormat.string(item.allocatedSize)).font(.body.monospacedDigit())
                        }
                        .font(.callout)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No scan yet", systemImage: "chart.bar", description: Text("Kind totals appear after a scan."))
        }
    }

    private func bar(title: String, color: Color, size: UInt64, count: Int, max: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(count.formatted()) · \(ByteFormat.string(size))")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: max == 0 ? 0 : proxy.size.width * Double(size) / Double(max))
                }
            }
            .frame(height: 8)
        }
    }
}

struct LogScreen: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Freed \(ByteFormat.string(model.log.totalFreedBytes))")
                    .font(.headline)
                Spacer()
                Text("\(model.log.records.count) records")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            if model.log.records.isEmpty {
                ContentUnavailableView(
                    "Nothing cleaned yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Previews and confirmed cleanups are recorded here, including how much space was freed.")
                )
            } else {
                List(model.log.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.title).font(.headline)
                            Spacer()
                            if record.dryRun {
                                Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            } else if record.succeeded {
                                Text(ByteFormat.string(record.bytesFreed))
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(DevDiskTheme.reclaim)
                            } else {
                                Text("Failed").foregroundStyle(.red)
                            }
                        }
                        HStack {
                            SafetyBadge(level: record.safety)
                            Text(record.timestamp, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.actionDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(record.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
#endif
