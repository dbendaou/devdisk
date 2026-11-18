#if os(macOS)
import AppKit
import Darwin
import Foundation
import DevDiskCore

@MainActor
enum MacActions {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder. Scan your home folder to see every cleanup rule."
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func volumeName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName, !name.isEmpty {
            return name
        }
        return url.lastPathComponent
    }
}

struct MacCleanupPerformer: CleanupPerforming {
    var isCancelled: @Sendable () -> Bool = { false }

    func moveToTrash(path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    func removePermanently(path: String) throws {
        if isCancelled() { throw CancellationError() }
        // lstat, so a symlink is removed itself. fileExists follows the link and
        // would skip a dangling one, or report a target that is already gone.
        guard Self.inodeExists(path) else { return }
        let source = URL(fileURLWithPath: path)
        let aside = source.deletingLastPathComponent()
            .appendingPathComponent(".devdisk-deleting-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        do {
            // The aside sits in the same parent, so this is a rename on that volume.
            // temporaryDirectory is often /var/folders on the system disk; moveItem
            // across volumes copies the tree instead of returning EXDEV.
            try fm.moveItem(at: source, to: aside)
        } catch {
            if Self.inodeExists(path) {
                try fm.removeItem(at: source)
                return
            }
            if Self.inodeExists(aside.path) {
                try fm.removeItem(at: aside)
                return
            }
            throw error
        }
        try fm.removeItem(at: aside)
    }

    private static func inodeExists(_ path: String) -> Bool {
        var info = stat()
        return path.withCString { lstat($0, &info) } == 0
    }

    func run(executable: String, arguments: [String]) throws -> String {
        guard CommandAllowlist.isAllowed(executable) else {
            throw SafetyViolation.commandNotAllowed(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        var environment = ProcessInfo.processInfo.environment
        let prefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = prefix + ":" + existing
        } else {
            environment["PATH"] = prefix
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // readToEnd drains the pipe until the process closes it, so a large
        // brew or docker report cannot fill the pipe and stall waitUntilExit.
        // Poll cancellation on another queue so a long command can be stopped.
        let dataBox = DataBox()
        let finishedReading = DispatchGroup()
        finishedReading.enter()
        let reader = Thread {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            dataBox.store(data)
            finishedReading.leave()
        }
        reader.start()
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        finishedReading.wait()
        let data = dataBox.load()
        let text = String(data: data, encoding: .utf8) ?? ""
        if isCancelled() {
            throw CancellationError()
        }
        if process.terminationStatus != 0 {
            throw CleanupFailure(message: "\(executable) exited with status \(process.terminationStatus).\n\(text)")
        }
        return text
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum RemovalLogStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("DevDisk", isDirectory: true)
            .appendingPathComponent("removal-log.json")
    }

    static func load() -> RemovalLog {
        guard let data = try? Data(contentsOf: fileURL) else { return RemovalLog() }
        return (try? JSONDecoder().decode(RemovalLog.self, from: data)) ?? RemovalLog()
    }

    static func save(_ log: RemovalLog) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(log).write(to: url, options: .atomic)
    }
}
#endif
