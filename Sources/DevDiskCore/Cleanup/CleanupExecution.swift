import Foundation

public struct CleanupFailure: Error, Sendable, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

extension CleanupFailure: LocalizedError {
    public var errorDescription: String? { message }
}

public protocol CleanupPerforming: Sendable {
    func moveToTrash(path: String) throws
    func removePermanently(path: String) throws
    func run(executable: String, arguments: [String]) throws -> String
}

public struct RemovalRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var ruleID: String
    public var title: String
    public var safety: SafetyLevel
    public var bytesFreed: UInt64
    public var estimatedBytes: UInt64
    public var paths: [String]
    public var actionDescription: String
    public var dryRun: Bool
    public var succeeded: Bool
    public var message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        ruleID: String,
        title: String,
        safety: SafetyLevel,
        bytesFreed: UInt64,
        estimatedBytes: UInt64,
        paths: [String],
        actionDescription: String,
        dryRun: Bool,
        succeeded: Bool,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.ruleID = ruleID
        self.title = title
        self.safety = safety
        self.bytesFreed = bytesFreed
        self.estimatedBytes = estimatedBytes
        self.paths = paths
        self.actionDescription = actionDescription
        self.dryRun = dryRun
        self.succeeded = succeeded
        self.message = message
    }
}

public struct RemovalLog: Sendable, Codable, Equatable {
    public var records: [RemovalRecord]

    public init(records: [RemovalRecord] = []) {
        self.records = records
    }

    public var totalFreedBytes: UInt64 {
        records.reduce(0) { partial, record in
            guard record.succeeded, !record.dryRun else { return partial }
            return partial + record.bytesFreed
        }
    }
}

public struct ConfirmationCopy: Sendable, Equatable {
    public var title: String
    public var detail: String
    public var confirmTitle: String
    public var paths: [String]
    public var totalBytes: UInt64
    public var dryRun: Bool
    public var safety: SafetyLevel
    /// Review deletes need a second explicit acknowledgement in the sheet.
    public var requiresExtraAcknowledgement: Bool

    public init(
        title: String,
        detail: String,
        confirmTitle: String,
        paths: [String],
        totalBytes: UInt64,
        dryRun: Bool,
        safety: SafetyLevel,
        requiresExtraAcknowledgement: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.paths = paths
        self.totalBytes = totalBytes
        self.dryRun = dryRun
        self.safety = safety
        self.requiresExtraAcknowledgement = requiresExtraAcknowledgement
    }
}

public enum ConfirmationBuilder {
    public static func make(_ suggestion: CleanupSuggestion, dryRun: Bool, trashInstead: Bool = false) -> ConfirmationCopy {
        let size = ByteFormat.string(suggestion.size)
        let count = suggestion.items.count
        let review = suggestion.safety == .review
            ? " This is marked Review because it may contain data you care about."
            : ""
        let extra = suggestion.safety == .review && !dryRun
        let deletes = suggestion.effect == .removePermanently && !trashInstead
        if dryRun {
            return ConfirmationCopy(
                title: "Preview \(suggestion.headline)?",
                detail: "Nothing will be deleted or run. DevDisk will only record this preview in the log.\(review)",
                confirmTitle: "Record preview",
                paths: suggestion.paths,
                totalBytes: suggestion.size,
                dryRun: true,
                safety: suggestion.safety,
                requiresExtraAcknowledgement: false
            )
        }
        if deletes {
            return ConfirmationCopy(
                title: "Delete permanently?",
                detail: "Delete permanently, can't be undone. This removes \(size) across \(count) \(count == 1 ? "path" : "paths").\(review)",
                confirmTitle: "Delete permanently",
                paths: suggestion.paths,
                totalBytes: suggestion.size,
                dryRun: false,
                safety: suggestion.safety,
                requiresExtraAcknowledgement: extra
            )
        }
        switch suggestion.effect {
        case .removePermanently, .moveToTrash:
            return ConfirmationCopy(
                title: "Move \(count) \(count == 1 ? "path" : "paths") to Trash?",
                detail: "DevDisk will move \(size) to Trash. You can restore the items from Trash until you empty it.\(review)",
                confirmTitle: "Move to Trash",
                paths: suggestion.paths,
                totalBytes: suggestion.size,
                dryRun: false,
                safety: suggestion.safety,
                requiresExtraAcknowledgement: extra
            )
        case .emptyTrash:
            return ConfirmationCopy(
                title: "Permanently delete Trash contents?",
                detail: "These \(count) items (\(size)) are already in Trash. Deleting them frees the space and cannot be undone.",
                confirmTitle: "Delete permanently",
                paths: suggestion.paths,
                totalBytes: suggestion.size,
                dryRun: false,
                safety: suggestion.safety
            )
        case .command(_, _, let display, _):
            return ConfirmationCopy(
                title: "Run \(display)?",
                detail: "DevDisk will run `\(display)`. It will not delete the listed files itself. The on-disk size is \(size); the command may free only part of it.\(review)",
                confirmTitle: "Run command",
                paths: suggestion.paths,
                totalBytes: suggestion.size,
                dryRun: false,
                safety: suggestion.safety
            )
        case .commandForEach(_, _, let display, _):
            return ConfirmationCopy(
                title: "Run \(display)?",
                detail: "DevDisk will run `\(display)` once per repository. It will not delete the repositories. The on-disk size is \(size), which is an upper bound.\(review)",
                confirmTitle: "Run command",
                paths: suggestion.paths,
                totalBytes: suggestion.size,
                dryRun: false,
                safety: suggestion.safety
            )
        }
    }
}

public struct CleanupExecutor: Sendable {
    public var performer: any CleanupPerforming

    public init(performer: any CleanupPerforming) {
        self.performer = performer
    }

    /// Safety checks run before any trash, delete, or command. A dry run records a log entry
    /// and does not call the performer. A mid-list failure stops and reports the bytes already moved.
    public func execute(
        _ suggestion: CleanupSuggestion,
        scanRoot: String,
        dryRun: Bool,
        now: Date = Date(),
        trashInstead: Bool = false
    ) throws -> RemovalRecord {
        if suggestion.items.isEmpty {
            throw SafetyViolation.emptySelection
        }
        for item in suggestion.items {
            if let violation = PathSafety.violation(for: item.path, scanRoot: scanRoot) {
                throw violation
            }
        }
        if case .emptyTrash = suggestion.effect {
            for item in suggestion.items where Paths.name(Paths.parent(item.path)) != ".Trash" {
                throw SafetyViolation.notTrashChild(item.path)
            }
        }
        if let executable = suggestion.effect.executableName, !CommandAllowlist.isAllowed(executable) {
            throw SafetyViolation.commandNotAllowed(executable)
        }
        if case .commandForEach(_, _, _, let usesParent) = suggestion.effect {
            for item in suggestion.items {
                let target = usesParent ? Paths.parent(item.path) : item.path
                if let violation = commandTargetViolation(target, scanRoot: scanRoot) {
                    throw violation
                }
            }
        }

        if dryRun {
            if case .command(let executable, _, let display, let preview?) = suggestion.effect {
                return runCommand(
                    suggestion,
                    now: now,
                    executable: executable,
                    arguments: preview,
                    display: "\(display) (preview)",
                    dryRun: true
                )
            }
            return record(
                suggestion,
                now: now,
                bytesFreed: 0,
                paths: suggestion.paths,
                dryRun: true,
                succeeded: true,
                message: "Preview only. Nothing was changed."
            )
        }

        switch suggestion.effect {
        case .removePermanently where trashInstead:
            return apply(suggestion, now: now, trashed: true) { path in
                try performer.moveToTrash(path: path)
            }
        case .removePermanently:
            return apply(suggestion, now: now) { path in
                try performer.removePermanently(path: path)
            }
        case .moveToTrash:
            return apply(suggestion, now: now, trashed: true) { path in
                try performer.moveToTrash(path: path)
            }
        case .emptyTrash:
            return apply(suggestion, now: now) { path in
                try performer.removePermanently(path: path)
            }
        case .command(let executable, let arguments, let display, _):
            return runCommand(suggestion, now: now, executable: executable, arguments: arguments, display: display, dryRun: false)
        case .commandForEach(let executable, let arguments, let display, let usesParent):
            return runForEach(suggestion, now: now, executable: executable, arguments: arguments, display: display, usesParent: usesParent)
        }
    }

    private func commandTargetViolation(_ path: String, scanRoot: String) -> SafetyViolation? {
        let path = Paths.normalize(path)
        let root = Paths.normalize(scanRoot)
        if path != root && !Paths.isStrictlyInside(path, root: root) {
            return .outsideRoot(path)
        }
        if PathSafety.isProtected(path) {
            return .protected(path)
        }
        return nil
    }

    private func runCommand(
        _ suggestion: CleanupSuggestion,
        now: Date,
        executable: String,
        arguments: [String],
        display: String,
        dryRun: Bool
    ) -> RemovalRecord {
        do {
            let output = try performer.run(executable: executable, arguments: arguments)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = trimmed.count > 2_000 ? String(trimmed.suffix(2_000)) : trimmed
            let message = tail.isEmpty ? "Finished `\(display)`." : "Finished `\(display)`.\n\(tail)"
            return record(suggestion, now: now, bytesFreed: 0, paths: suggestion.paths, dryRun: dryRun, succeeded: true, message: message)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return record(suggestion, now: now, bytesFreed: 0, paths: [], dryRun: dryRun, succeeded: false, message: message)
        }
    }

    private func runForEach(
        _ suggestion: CleanupSuggestion,
        now: Date,
        executable: String,
        arguments: [String],
        display: String,
        usesParent: Bool
    ) -> RemovalRecord {
        var done: [String] = []
        for item in suggestion.items {
            let target = usesParent ? Paths.parent(item.path) : item.path
            let resolved = arguments.map { $0.replacingOccurrences(of: "{path}", with: target) }
            do {
                _ = try performer.run(executable: executable, arguments: resolved)
                done.append(item.path)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                let prefix = done.isEmpty ? "Stopped before the command ran." : "Stopped after \(done.count) repositories."
                return record(suggestion, now: now, bytesFreed: 0, paths: done, dryRun: false, succeeded: false, message: "\(prefix) \(message)")
            }
        }
        return record(
            suggestion,
            now: now,
            bytesFreed: 0,
            paths: done,
            dryRun: false,
            succeeded: true,
            message: "Ran `\(display)` in \(done.count) \(done.count == 1 ? "repository" : "repositories")."
        )
    }

    private func apply(
        _ suggestion: CleanupSuggestion,
        now: Date,
        trashed: Bool = false,
        action: (String) throws -> Void
    ) -> RemovalRecord {
        var freed: UInt64 = 0
        var done: [String] = []
        for item in suggestion.items {
            do {
                try action(item.path)
                freed += item.bytes
                done.append(item.path)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                let prefix = done.isEmpty ? "Stopped before anything was removed." : "Stopped after \(done.count) paths (\(ByteFormat.string(freed)))."
                return record(
                    suggestion,
                    now: now,
                    bytesFreed: freed,
                    paths: done,
                    dryRun: false,
                    succeeded: false,
                    message: "\(prefix) \(message)"
                )
            }
        }
        let permanently = !trashed && (suggestion.effect == .removePermanently || suggestion.effect == .emptyTrash)
        let verb = permanently ? "Deleted" : "Moved"
        let destination = permanently ? " permanently" : " to Trash"
        return record(
            suggestion,
            now: now,
            bytesFreed: freed,
            paths: done,
            dryRun: false,
            succeeded: true,
            message: "\(verb) \(done.count) \(done.count == 1 ? "path" : "paths")\(destination) (\(ByteFormat.string(freed)))."
        )
    }

    private func record(
        _ suggestion: CleanupSuggestion,
        now: Date,
        bytesFreed: UInt64,
        paths: [String],
        dryRun: Bool,
        succeeded: Bool,
        message: String
    ) -> RemovalRecord {
        RemovalRecord(
            timestamp: now,
            ruleID: suggestion.ruleID,
            title: suggestion.headline,
            safety: suggestion.safety,
            bytesFreed: bytesFreed,
            estimatedBytes: suggestion.size,
            paths: paths,
            actionDescription: suggestion.actionDescription,
            dryRun: dryRun,
            succeeded: succeeded,
            message: message
        )
    }
}
