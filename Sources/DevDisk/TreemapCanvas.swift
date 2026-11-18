#if os(macOS)
import SwiftUI
import DevDiskCore

struct TreemapScreen: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            GeometryReader { proxy in
                let pulsing = model.mapScanning || model.placed.contains(where: \.isPartial)
                TimelineView(.animation(minimumInterval: 0.6, paused: !pulsing)) { timeline in
                    let pulse = 0.35 + 0.4 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 2.5))
                    Canvas { context, _ in
                        for rect in model.placed {
                            let draw = inset(rect)
                            guard draw.width > 0.5, draw.height > 0.5 else { continue }
                            let cg = CGRect(x: draw.x, y: draw.y, width: draw.width, height: draw.height)
                            let path = Path(roundedRect: cg, cornerRadius: 3)
                            if rect.isPartial {
                                context.fill(path, with: .color(Color.secondary.opacity(pulse)))
                            } else if rect.role == .leaf {
                                context.fill(path, with: .color(rect.kind.color.opacity(rect.nodeID == model.selectedID ? 1 : 0.88)))
                                if draw.width > 72, draw.height > 22 {
                                    context.draw(
                                        Text(rect.title).font(.caption2).foregroundStyle(.white),
                                        at: CGPoint(x: cg.minX + 6, y: cg.minY + 8),
                                        anchor: .topLeading
                                    )
                                }
                            } else {
                                context.stroke(path, with: .color(Color.primary.opacity(0.18)), lineWidth: 1)
                            }
                            if rect.nodeID == model.selectedID {
                                context.stroke(path, with: .color(Color.white), lineWidth: 2)
                            }
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { event in
                            select(model.placed, at: event.location)
                        }
                    )
                }
                .onAppear {
                    model.noteMapSize(width: proxy.size.width, height: proxy.size.height)
                }
                .onChange(of: proxy.size) { _, size in
                    model.noteMapSize(width: size.width, height: size.height)
                }
            }
            .onChange(of: model.zoomPath) { _, _ in
                model.relayout()
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            inspector
            legend
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
                    Button(crumb.name) { model.zoomPath = crumb.path }
                        .buttonStyle(.borderless)
                    if crumb.path != model.zoomPath {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var inspector: some View {
        HStack(spacing: 12) {
            if let node = model.selectedNode {
                Circle().fill(node.kind.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.headline).lineLimit(1)
                    Text(node.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(node.kind.label).foregroundStyle(.secondary)
                Text(ByteFormat.string(node.allocatedSize)).font(.body.monospacedDigit())
                if node.isDirectory {
                    Button("Open") { model.zoomPath = node.path }
                }
                Button("Reveal in Finder") { MacActions.reveal(node.path) }
            } else {
                Text("Click a block to select it. Click it again to open a folder or reveal a file.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var legend: some View {
        let kinds = model.tree.map { UsageSummary.kinds(in: $0.root) } ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(kinds.prefix(8)) { total in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(total.kind.color)
                            .frame(width: 10, height: 10)
                        Text("\(total.kind.label) \(ByteFormat.string(total.allocatedSize))")
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func inset(_ rect: LayoutRect) -> TreemapFrame {
        let pad = rect.role == .leaf ? 1.25 : 0.0
        guard rect.frame.width > pad * 2, rect.frame.height > pad * 2 else { return rect.frame }
        return TreemapFrame(
            x: rect.frame.x + pad,
            y: rect.frame.y + pad,
            width: rect.frame.width - pad * 2,
            height: rect.frame.height - pad * 2
        )
    }

    private func select(_ rects: [LayoutRect], at point: CGPoint) {
        guard let hit = rects.last(where: { $0.frame.contains(point.x, point.y) }) else { return }
        if model.selectedID == hit.nodeID, let node = model.tree?.root.node(id: hit.nodeID) {
            if node.isDirectory {
                model.zoomPath = node.path
            } else {
                MacActions.reveal(node.path)
            }
        } else {
            model.selectedID = hit.nodeID
        }
    }

    private var crumbs: [(name: String, path: String)] {
        guard let root = model.rootPath, let zoom = model.zoomPath ?? model.tree?.root.path else { return [] }
        var items: [(String, String)] = [(Paths.name(root), root)]
        guard zoom != root, zoom.hasPrefix(root == "/" ? "/" : root + "/") else { return items }
        let relative = zoom.dropFirst(root.count).split(separator: "/").map(String.init)
        var path = root
        for part in relative {
            path = Paths.join(path, part)
            items.append((part, path))
        }
        return items
    }
}
#endif
