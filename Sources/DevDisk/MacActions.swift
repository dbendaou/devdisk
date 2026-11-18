#if os(macOS)
import AppKit
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
    func moveToTrash(path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    func removePermanently(path: String) throws {
        let source = URL(fileURLWithPath: path)
        // A retry after a partial delete should continue with the paths that remain.
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDisk-\(UUID().uuidString)", isDirectory: true)
        // Same-volume rename returns immediately so the scan no longer sees the path.
        // The bytes are freed when the renamed copy is removed, still off the main thread.
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.removeItem(at: destination)
        } catch {
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.removeItem(at: source)
            } else if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            } else {
                throw error
            }
        }
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
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw CleanupFailure(message: "\(executable) exited with status \(process.terminationStatus).\n\(text)")
        }
        return text
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
