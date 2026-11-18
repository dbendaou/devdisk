import Foundation

public struct CleanupEngine: Sendable {
    public init() {}

    /// `byteFloor` replaces every rule's minimum, including per-file thresholds. Tests use it
    /// so fixtures can stay small. Pass `nil` for the catalog's real thresholds.
    public func evaluate(
        root: ScanNode,
        rules: [RuleSpec] = CleanupCatalog.all,
        now: Date = Date(),
        byteFloor: UInt64? = nil,
        staleAfterDays: Int = CleanupCatalog.defaultStaleDays
    ) -> CleanupReport {
        var state = EvalState(
            root: root,
            now: now,
            byteFloor: byteFloor,
            staleAfterDays: max(0, staleAfterDays)
        )
        var suggestions: [CleanupSuggestion] = []
        for rule in rules {
            suggestions.append(contentsOf: state.evaluate(rule))
        }
        suggestions.sort { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.id < rhs.id
        }
        let counting = suggestions.filter(\.countsTowardEstimate)
        let safe = counting.filter { $0.safety == .safe }.reduce(UInt64(0)) { $0 + $1.size }
        let review = counting.filter { $0.safety == .review }.reduce(UInt64(0)) { $0 + $1.size }
        let firm = counting.filter { !$0.estimateIsUpperBound }.reduce(UInt64(0)) { $0 + $1.size }
        let upper = counting.filter(\.estimateIsUpperBound).reduce(UInt64(0)) { $0 + $1.size }
        return CleanupReport(
            suggestions: suggestions,
            estimatedReclaimableBytes: safe + review,
            safeBytes: safe,
            reviewBytes: review,
            firmBytes: firm,
            upperBoundBytes: upper,
            skippedProtected: state.skippedProtected.sorted()
        )
    }
}

private struct EvalState {
    var root: ScanNode
    var now: Date
    var byteFloor: UInt64?
    var staleAfterDays: Int
    var claimed: Set<String> = []
    var skippedProtected: [String] = []

    func floor(_ rule: RuleSpec) -> UInt64 {
        byteFloor ?? rule.minimumBytes
    }

    mutating func evaluate(_ rule: RuleSpec) -> [CleanupSuggestion] {
        switch rule.locator {
        case .relativeDirectories(let relatives):
            return grouped(rule, nodes: relatives.compactMap { node(relative: $0) })
        case .childDirectories(let under):
            guard let parent = node(relative: under) else { return [] }
            return parent.children.compactMap { child in
                guard child.isDirectory else { return nil }
                return single(rule, node: child, name: "\(child.name) cache", idSuffix: child.name)
            }
        case .directoriesNamed(let names, let age, let sibling, let siblingExtension):
            var found: [ScanNode] = []
            collectNamed(
                root,
                parent: nil,
                names: Set(names),
                age: age,
                sibling: sibling,
                siblingExtension: siblingExtension,
                into: &found
            )
            return grouped(rule, nodes: found)
        case .directoriesEndingWith(let suffix, let age):
            var found: [ScanNode] = []
            collectSuffix(root, suffix: suffix, age: age, into: &found)
            return grouped(rule, nodes: found)
        case .directoriesContainingFile(let marker, let age):
            var found: [ScanNode] = []
            collectMarked(root, parent: nil, marker: marker, age: age, into: &found)
            return grouped(rule, nodes: found)
        case .files(let under, let names, let extensions, let largerThan, let age):
            let minimum = byteFloor ?? largerThan
            let scope: ScanNode
            if let under {
                guard let found = node(relative: under) else { return [] }
                scope = found
            } else {
                scope = root
            }
            var found: [ScanNode] = []
            collectFiles(
                scope,
                parent: nil,
                names: Set(names),
                extensions: Set(extensions.map { $0.lowercased() }),
                minimum: minimum,
                age: age,
                into: &found
            )
            return grouped(rule, nodes: found)
        }
    }

    mutating func grouped(_ rule: RuleSpec, nodes: [ScanNode]) -> [CleanupSuggestion] {
        let accepted = accept(nodes, effect: rule.effect)
        guard !accepted.isEmpty else { return [] }
        let items = items(from: accepted, rule: rule)
        guard !items.isEmpty, items.reduce(UInt64(0), { $0 + $1.bytes }) >= floor(rule) else { return [] }
        for node in accepted { claim(node.path) }
        return [make(rule, id: rule.id, name: rule.name, summary: rule.summary, items: items)]
    }

    mutating func single(_ rule: RuleSpec, node: ScanNode, name: String, idSuffix: String) -> CleanupSuggestion? {
        let accepted = accept([node], effect: rule.effect)
        guard accepted.count == 1, let only = accepted.first else { return nil }
        let items = items(from: [only], rule: rule)
        let size = items.reduce(UInt64(0)) { $0 + $1.bytes }
        guard size >= floor(rule), !items.isEmpty else { return nil }
        claim(only.path)
        let summary = rule.summary + " Folder: \(only.name)."
        return make(rule, id: "\(rule.id)/\(idSuffix)", name: name, summary: summary, items: items)
    }

    mutating func items(from nodes: [ScanNode], rule: RuleSpec) -> [CleanupPath] {
        var paths: [CleanupPath] = []
        for node in nodes {
            if case .emptyTrash = rule.effect {
                for child in node.children {
                    if PathSafety.violation(for: child.path, scanRoot: root.path) != nil || PathSafety.containsProtected(child) {
                        skippedProtected.append(child.path)
                        continue
                    }
                    paths.append(CleanupPath(path: child.path, bytes: child.allocatedSize))
                }
            } else {
                let context = projectContext(for: node, anchor: rule.projectAnchor)
                let modified = node.isDirectory ? context.date : (node.modified ?? context.date)
                paths.append(CleanupPath(
                    path: node.path,
                    bytes: node.allocatedSize,
                    projectName: context.name,
                    lastModified: modified
                ))
            }
        }
        paths.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.path < rhs.path
        }
        return paths
    }

    func projectContext(for node: ScanNode, anchor: ProjectAnchor) -> (name: String?, date: Date?) {
        switch anchor {
        case .none:
            return (nil, nil)
        case .parent:
            let parent = root.node(atPath: Paths.parent(node.path))
            return (parent?.name, parent?.modified ?? node.modified)
        case .grandparent:
            let parent = root.node(atPath: Paths.parent(node.path))
            let grand = parent.flatMap { root.node(atPath: Paths.parent($0.path)) }
            return (grand?.name ?? parent?.name, grand?.modified ?? parent?.modified ?? node.modified)
        }
    }

    func make(_ rule: RuleSpec, id: String, name: String, summary: String, items: [CleanupPath]) -> CleanupSuggestion {
        let size = items.reduce(UInt64(0)) { $0 + $1.bytes }
        return CleanupSuggestion(
            id: id,
            ruleID: rule.id,
            name: name,
            summary: summary,
            ecosystem: rule.ecosystem,
            safety: rule.safety,
            items: items,
            headline: headline(name: name, count: items.count, size: size, phrasing: rule.phrasing, days: staleAfterDays),
            actionDescription: actionDescription(effect: rule.effect, count: items.count),
            effect: rule.effect,
            countsTowardEstimate: rule.countsTowardEstimate,
            estimateIsUpperBound: rule.estimateIsUpperBound
        )
    }

    mutating func accept(_ nodes: [ScanNode], effect: CleanupEffect) -> [ScanNode] {
        var kept: [ScanNode] = []
        var seen: Set<String> = []
        for node in nodes {
            let path = Paths.normalize(node.path)
            if path == Paths.normalize(root.path) { continue }
            if seen.contains(path) || isClaimed(path) { continue }
            if node.errorMessage != nil || node.isOtherVolume { continue }
            if PathSafety.violation(for: path, scanRoot: root.path) != nil {
                skippedProtected.append(path)
                continue
            }
            // Moving a directory to Trash deletes every descendant. Emptying Trash
            // deletes listed children one by one, so protected children are filtered later.
            if (effect == .moveToTrash || effect == .removePermanently) && PathSafety.containsProtected(node) {
                skippedProtected.append(path)
                continue
            }
            seen.insert(path)
            kept.append(node)
        }
        return kept
    }

    func node(relative: String) -> ScanNode? {
        let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        if parts.isEmpty { return nil }
        var current = root
        for part in parts {
            guard let next = current.children.first(where: { $0.name == part }) else { return nil }
            current = next
        }
        return current
    }

    mutating func collectNamed(
        _ node: ScanNode,
        parent: ScanNode?,
        names: Set<String>,
        age: AgeFilter,
        sibling: String?,
        siblingExtension: String?,
        into found: inout [ScanNode]
    ) {
        if node.path != root.path && isClaimed(node.path) { return }
        if node.isDirectory && names.contains(node.name) {
            let namedOK = sibling == nil || parent?.children.contains(where: { $0.name == sibling }) == true
            let extensionOK = siblingExtension == nil || parent?.children.contains(where: {
                !$0.isDirectory && FileKind.extensionOf($0.name) == siblingExtension
            }) == true
            let siblingOK = namedOK && extensionOK
            if siblingOK && ageOK(parent: parent, node: node, filter: age) {
                found.append(node)
            }
            let requiresSibling = sibling != nil || siblingExtension != nil
            if !requiresSibling || siblingOK { return }
        }
        guard node.isDirectory, !node.isOtherVolume else { return }
        for child in node.children {
            collectNamed(
                child,
                parent: node,
                names: names,
                age: age,
                sibling: sibling,
                siblingExtension: siblingExtension,
                into: &found
            )
        }
    }

    mutating func collectSuffix(_ node: ScanNode, suffix: String, age: AgeFilter, into found: inout [ScanNode]) {
        if node.path != root.path && isClaimed(node.path) { return }
        guard node.isDirectory, !node.isOtherVolume else { return }
        let relative = relativePath(of: node)
        if relative == suffix || relative.hasSuffix("/" + suffix) {
            let parent = root.node(atPath: Paths.parent(node.path))
            if ageOK(parent: parent, node: node, filter: age) {
                found.append(node)
            }
            return
        }
        for child in node.children {
            collectSuffix(child, suffix: suffix, age: age, into: &found)
        }
    }

    mutating func collectMarked(
        _ node: ScanNode,
        parent: ScanNode?,
        marker: String,
        age: AgeFilter,
        into found: inout [ScanNode]
    ) {
        if node.path != root.path && isClaimed(node.path) { return }
        guard node.isDirectory, !node.isOtherVolume else { return }
        if node.children.contains(where: { !$0.isDirectory && $0.name == marker }) {
            if ageOK(parent: parent, node: node, filter: age) {
                found.append(node)
            }
            return
        }
        for child in node.children {
            collectMarked(child, parent: node, marker: marker, age: age, into: &found)
        }
    }

    mutating func collectFiles(
        _ node: ScanNode,
        parent: ScanNode?,
        names: Set<String>,
        extensions: Set<String>,
        minimum: UInt64,
        age: AgeFilter,
        into found: inout [ScanNode]
    ) {
        if isClaimed(node.path) { return }
        if node.isDirectory {
            if node.isOtherVolume || node.errorMessage != nil { return }
            for child in node.children {
                collectFiles(child, parent: node, names: names, extensions: extensions, minimum: minimum, age: age, into: &found)
            }
            return
        }
        if node.isSymlink || node.errorMessage != nil { return }
        if node.allocatedSize < minimum { return }
        let ext = FileKind.extensionOf(node.name)
        let nameOK = !names.isEmpty && names.contains(node.name)
        let extOK = !extensions.isEmpty && extensions.contains(ext)
        let anyFile = names.isEmpty && extensions.isEmpty
        guard anyFile || nameOK || extOK else { return }
        guard ageOK(parent: nil, node: node, filter: age) else { return }
        found.append(node)
    }

    func relativePath(of node: ScanNode) -> String {
        let rootPath = Paths.normalize(root.path)
        let path = Paths.normalize(node.path)
        guard path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    func ageOK(parent: ScanNode?, node: ScanNode, filter: AgeFilter) -> Bool {
        switch filter {
        case .any:
            return true
        case .olderThanThreshold:
            guard let date = parent?.modified ?? node.modified else {
                return staleAfterDays == 0
            }
            return now.timeIntervalSince(date) >= Double(staleAfterDays) * 86_400
        }
    }

    func isClaimed(_ path: String) -> Bool {
        var current = Paths.normalize(path)
        while true {
            if claimed.contains(current) { return true }
            let parent = Paths.parent(current)
            if parent == current { return false }
            current = parent
        }
    }

    mutating func claim(_ path: String) {
        claimed.insert(Paths.normalize(path))
    }

}

func headline(name: String, count: Int, size: UInt64, phrasing: CleanupPhrasing, days: Int) -> String {
    let sizeText = ByteFormat.string(size)
    switch phrasing {
    case .removeCount(let singular, let plural, let qualifier):
        let noun = count == 1 ? singular : plural
        let rendered: String
        if qualifier.contains("{days}") && days == 0 {
            rendered = " in any project"
        } else {
            rendered = qualifier.replacingOccurrences(of: "{days}", with: String(days))
        }
        return "Remove \(count) \(noun)\(rendered), \(sizeText)"
    case .clearNamed:
        return "Clear \(name), \(sizeText)"
    case .emptyTrash:
        return "Empty Trash, \(sizeText)"
    case .toolPrune:
        let bound = sizeText
        return "\(name), \(bound) on disk"
    }
}

func actionDescription(effect: CleanupEffect, count: Int) -> String {
    switch effect {
    case .removePermanently:
        "Delete \(count) \(count == 1 ? "path" : "paths") permanently"
    case .moveToTrash:
        "Move \(count) \(count == 1 ? "path" : "paths") to Trash"
    case .emptyTrash:
        "Permanently delete \(count) \(count == 1 ? "item" : "items") already in Trash"
    case .command(_, _, let display, _):
        "Run \(display)"
    case .commandForEach(_, _, let display, _):
        "Run \(display) in \(count) \(count == 1 ? "repository" : "repositories")"
    }
}
