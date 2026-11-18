import Foundation

public struct TreemapFrame: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && py >= y && px < x + width && py < y + height
    }
}

public struct TreemapWeight: Sendable, Equatable, Hashable {
    public var id: Int
    public var size: UInt64

    public init(id: Int, size: UInt64) {
        self.id = id
        self.size = size
    }
}

public struct TreemapPlacement: Sendable, Equatable, Hashable {
    public var id: Int
    public var frame: TreemapFrame

    public init(id: Int, frame: TreemapFrame) {
        self.id = id
        self.frame = frame
    }
}

public enum LayoutRole: String, Sendable, Equatable, Hashable {
    case container
    case leaf
}

public struct LayoutRect: Sendable, Equatable, Hashable, Identifiable {
    public var nodeID: Int
    public var frame: TreemapFrame
    public var depth: Int
    public var kind: FileKind
    public var role: LayoutRole
    public var title: String
    public var path: String
    public var allocatedSize: UInt64
    public var id: Int { nodeID }

    public init(
        nodeID: Int,
        frame: TreemapFrame,
        depth: Int,
        kind: FileKind,
        role: LayoutRole,
        title: String,
        path: String,
        allocatedSize: UInt64
    ) {
        self.nodeID = nodeID
        self.frame = frame
        self.depth = depth
        self.kind = kind
        self.role = role
        self.title = title
        self.path = path
        self.allocatedSize = allocatedSize
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk, 2000).
///
/// Rows are laid along the shorter side of the remaining rectangle. Adding the next
/// item stops when it would make the worst aspect ratio in the row worse. This is an
/// independent implementation of the published algorithm.
public enum SquarifiedTreemap {
    public static func layout(weights: [TreemapWeight], in frame: TreemapFrame) -> [TreemapPlacement] {
        let positive = weights.filter { $0.size > 0 }
        let total = positive.reduce(UInt64(0)) { $0 + $1.size }
        guard total > 0, frame.width > 0, frame.height > 0 else { return [] }
        let scale = frame.area / Double(total)
        var remaining: [(id: Int, area: Double)] = positive.map { ($0.id, Double($0.size) * scale) }
        var rect = frame
        var placed: [TreemapPlacement] = []
        while !remaining.isEmpty, rect.width > 0, rect.height > 0 {
            let side = min(rect.width, rect.height)
            var row: [(id: Int, area: Double)] = []
            while let next = remaining.first {
                if row.isEmpty || worst(row + [next], side: side) <= worst(row, side: side) {
                    row.append(next)
                    remaining.removeFirst()
                } else {
                    break
                }
            }
            placed.append(contentsOf: place(row, in: &rect))
        }
        return placed
    }

    public static func layout(node: ScanNode, in frame: TreemapFrame, maxDepth: Int = 7) -> [LayoutRect] {
        var output: [LayoutRect] = []
        emit(node, frame: frame, depth: 0, maxDepth: max(0, maxDepth), into: &output)
        return output
    }

    private static func emit(
        _ node: ScanNode,
        frame: TreemapFrame,
        depth: Int,
        maxDepth: Int,
        into output: inout [LayoutRect]
    ) {
        let kids = node.children.filter { $0.allocatedSize > 0 }
        let canExpand = node.isDirectory && !kids.isEmpty && depth < maxDepth && frame.width >= 2 && frame.height >= 2
        let kind = canExpand ? FileKind.folder : (node.isDirectory ? node.dominantFileKind() : node.kind)
        output.append(LayoutRect(
            nodeID: node.id,
            frame: frame,
            depth: depth,
            kind: kind,
            role: canExpand ? .container : .leaf,
            title: node.name,
            path: node.path,
            allocatedSize: node.allocatedSize
        ))
        guard canExpand else { return }
        let weights = kids.map { TreemapWeight(id: $0.id, size: $0.allocatedSize) }
        let placed = layout(weights: weights, in: frame)
        let frames = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.frame) })
        for child in kids {
            guard let childFrame = frames[child.id] else { continue }
            emit(child, frame: childFrame, depth: depth + 1, maxDepth: maxDepth, into: &output)
        }
    }

    /// Worst aspect ratio in a row. `side` is the length of the shorter side the row is laid along.
    private static func worst(_ row: [(id: Int, area: Double)], side: Double) -> Double {
        guard side > 0, !row.isEmpty else { return .infinity }
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, let maxArea = row.map(\.area).max(), let minArea = row.map(\.area).min(), minArea > 0 else {
            return .infinity
        }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * maxArea / sum2, sum2 / (side2 * minArea))
    }

    private static func place(_ row: [(id: Int, area: Double)], in rect: inout TreemapFrame) -> [TreemapPlacement] {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, !row.isEmpty else { return [] }
        var placed: [TreemapPlacement] = []
        if rect.width >= rect.height {
            let colWidth = min(rect.width, sum / rect.height)
            var y = rect.y
            for (index, item) in row.enumerated() {
                let height: Double
                if index == row.count - 1 {
                    height = max(0, rect.y + rect.height - y)
                } else {
                    height = colWidth > 0 ? item.area / colWidth : 0
                }
                placed.append(TreemapPlacement(
                    id: item.id,
                    frame: TreemapFrame(x: rect.x, y: y, width: colWidth, height: height)
                ))
                y += height
            }
            rect.x += colWidth
            rect.width -= colWidth
        } else {
            let rowHeight = min(rect.height, sum / rect.width)
            var x = rect.x
            for (index, item) in row.enumerated() {
                let width: Double
                if index == row.count - 1 {
                    width = max(0, rect.x + rect.width - x)
                } else {
                    width = rowHeight > 0 ? item.area / rowHeight : 0
                }
                placed.append(TreemapPlacement(
                    id: item.id,
                    frame: TreemapFrame(x: x, y: rect.y, width: width, height: rowHeight)
                ))
                x += width
            }
            rect.y += rowHeight
            rect.height -= rowHeight
        }
        return placed
    }
}
