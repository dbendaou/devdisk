import Foundation
import Testing
@testable import DevDiskCore

struct FormatAndLayoutTests {
    @Test func decimalSizes() {
        #expect(ByteFormat.string(0) == "0 B")
        #expect(ByteFormat.string(999) == "999 B")
        #expect(ByteFormat.string(1_000) == "1 KB")
        #expect(ByteFormat.string(1_500) == "1.5 KB")
        #expect(ByteFormat.string(1_000_000) == "1 MB")
        #expect(ByteFormat.string(16_000_000_000) == "16 GB")
        #expect(ByteFormat.string(18_400_000_000) == "18.4 GB")
        #expect(ByteFormat.string(900_000_000) == "900 MB")
        #expect(ByteFormat.string(4_900_000_000) == "4.9 GB")
    }

    @Test func fileKinds() {
        #expect(FileKind.classify(name: "Photo.PNG") == .image)
        #expect(FileKind.classify(name: "app.dmg") == .diskImage)
        #expect(FileKind.classify(name: "data.sqlite") == .database)
        #expect(FileKind.classify(name: "main.swift") == .code)
        #expect(FileKind.classify(name: "Makefile") == .other)
        #expect(FileKind.extensionOf("archive.tar.gz") == "gz")
    }

    @Test func classicSquarifiedLayout() {
        let weights = [
            TreemapWeight(id: 1, size: 6),
            TreemapWeight(id: 2, size: 6),
            TreemapWeight(id: 3, size: 4),
            TreemapWeight(id: 4, size: 3),
            TreemapWeight(id: 5, size: 2),
            TreemapWeight(id: 6, size: 2),
            TreemapWeight(id: 7, size: 1),
        ]
        let frame = TreemapFrame(x: 0, y: 0, width: 6, height: 4)
        let placed = SquarifiedTreemap.layout(weights: weights, in: frame)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.frame) })
        #expect(placed.count == 7)
        expectFrame(byID[1], x: 0, y: 0, width: 3, height: 2)
        expectFrame(byID[2], x: 0, y: 2, width: 3, height: 2)
        expectFrame(byID[3], x: 3, y: 0, width: 12.0 / 7.0, height: 7.0 / 3.0)
        expectFrame(byID[4], x: 3 + 12.0 / 7.0, y: 0, width: 9.0 / 7.0, height: 7.0 / 3.0)
        expectFrame(byID[5], x: 3, y: 7.0 / 3.0, width: 1.2, height: 5.0 / 3.0)
        expectFrame(byID[6], x: 4.2, y: 7.0 / 3.0, width: 1.2, height: 5.0 / 3.0)
        expectFrame(byID[7], x: 5.4, y: 7.0 / 3.0, width: 0.6, height: 5.0 / 3.0)

        let area = placed.reduce(0) { $0 + $1.frame.area }
        #expect(abs(area - frame.area) < 0.000_001)
        assertTiled(placed.map(\.frame), in: frame)
    }

    @Test func singleWeightFillsTheFrame() {
        let frame = TreemapFrame(x: 2, y: 3, width: 10, height: 4)
        let placed = SquarifiedTreemap.layout(weights: [TreemapWeight(id: 8, size: 5)], in: frame)
        #expect(placed.count == 1)
        expectFrame(placed.first?.frame, x: 2, y: 3, width: 10, height: 4)
    }

    @Test func zeroWeightsAreDropped() {
        let placed = SquarifiedTreemap.layout(
            weights: [TreemapWeight(id: 1, size: 0), TreemapWeight(id: 2, size: 4)],
            in: TreemapFrame(x: 0, y: 0, width: 2, height: 2)
        )
        #expect(placed.map(\.id) == [2])
    }

    @Test func nestedLeavesFillTheFrame() {
        let files = [
            ScanNode(id: 2, name: "a.png", path: "/a.png", kind: .image, allocatedSize: 50),
            ScanNode(id: 3, name: "b.swift", path: "/b.swift", kind: .code, allocatedSize: 30),
            ScanNode(id: 4, name: "c.db", path: "/c.db", kind: .database, allocatedSize: 20),
        ]
        let root = ScanNode(
            id: 1, name: "root", path: "/", kind: .folder, allocatedSize: 100,
            isDirectory: true, children: files
        )
        let frame = TreemapFrame(x: 0, y: 0, width: 200, height: 100)
        let rects = SquarifiedTreemap.layout(node: root, in: frame, maxDepth: 4)
        let leaves = rects.filter { $0.role == .leaf }
        #expect(leaves.count == 3)
        let area = leaves.reduce(0) { $0 + $1.frame.area }
        #expect(abs(area - frame.area) < 0.001)
        #expect(rects.contains { $0.role == .container && $0.nodeID == 1 })
        assertTiled(leaves.map(\.frame), in: frame)
    }

    @Test func collapsedDepthIsOneLeaf() {
        let root = ScanNode(
            id: 1, name: "root", path: "/", kind: .folder, allocatedSize: 10,
            isDirectory: true,
            children: [ScanNode(id: 2, name: "a", path: "/a", kind: .code, allocatedSize: 10)]
        )
        let rects = SquarifiedTreemap.layout(
            node: root,
            in: TreemapFrame(x: 0, y: 0, width: 10, height: 10),
            maxDepth: 0
        )
        #expect(rects.count == 1)
        #expect(rects[0].role == .leaf)
        #expect(rects[0].kind == .code)
    }

    @Test func outlineSortAndKindTotals() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let root = ScanNode(
            id: 1, name: "root", path: "/r", kind: .folder, allocatedSize: 30, isDirectory: true,
            children: [
                ScanNode(id: 2, name: "b.txt", path: "/r/b.txt", kind: .document, allocatedSize: 10, modified: older),
                ScanNode(id: 3, name: "a.png", path: "/r/a.png", kind: .image, allocatedSize: 20, modified: newer),
            ]
        )
        let bySize = OutlineOrder.size.sorted(root.children)
        #expect(bySize.map { $0.name } == ["a.png", "b.txt"])
        let byName = OutlineOrder.name.sorted(root.children)
        #expect(byName.map { $0.name } == ["a.png", "b.txt"])
        let byModified = OutlineOrder.modified.sorted(root.children)
        #expect(byModified.map { $0.name } == ["a.png", "b.txt"])
        let kinds = UsageSummary.kinds(in: root)
        #expect(kinds.map { $0.kind } == [FileKind.image, FileKind.document])
        #expect(kinds[0].allocatedSize == 20)
        let extensions = UsageSummary.extensions(in: root)
        #expect(extensions.map { $0.extensionName } == ["png", "txt"])
    }

    @Test func volumeStatsAreReadable() {
        let stats = VolumeProbe.stats(at: "/tmp")
        #expect(stats != nil)
        #expect((stats?.totalBytes ?? 0) > 0)
        #expect((stats?.availableBytes ?? 0) <= (stats?.totalBytes ?? 0))
    }
}

private func expectFrame(_ frame: TreemapFrame?, x: Double, y: Double, width: Double, height: Double) {
    let frame = frame!
    #expect(abs(frame.x - x) < 0.000_001)
    #expect(abs(frame.y - y) < 0.000_001)
    #expect(abs(frame.width - width) < 0.000_001)
    #expect(abs(frame.height - height) < 0.000_001)
}

private func assertTiled(_ frames: [TreemapFrame], in bounds: TreemapFrame) {
    for frame in frames {
        #expect(frame.x >= bounds.x - 0.000_001)
        #expect(frame.y >= bounds.y - 0.000_001)
        #expect(frame.x + frame.width <= bounds.x + bounds.width + 0.000_001)
        #expect(frame.y + frame.height <= bounds.y + bounds.height + 0.000_001)
        #expect(frame.width >= -0.000_001)
        #expect(frame.height >= -0.000_001)
    }
    for left in frames.indices {
        for right in frames.indices where right > left {
            #expect(!overlaps(frames[left], frames[right]))
        }
    }
}

private func overlaps(_ lhs: TreemapFrame, _ rhs: TreemapFrame) -> Bool {
    let width = min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x)
    let height = min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y)
    return width > 0.000_001 && height > 0.000_001
}
