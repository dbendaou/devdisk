import Foundation

/// Whether the Safe-batch confirmation is on screen, and how far a running batch has got.
/// Confirming always clears the sheet before `running` becomes true, so work is not tied to the sheet.
public struct SafeBatchCoordinator: Sendable, Equatable {
    public var sheetPresented = false
    public var running = false
    public var completed = 0
    public var total = 0
    public var freed: UInt64 = 0
    public var failed = 0
    public var bannerVisible = false
    public var summaryPresented = false

    public init() {}

    public mutating func presentSheet() {
        sheetPresented = true
        summaryPresented = false
    }

    /// Closes the confirmation sheet, then marks the batch running.
    /// Callers must not start deletions until this returns true (`workMayStart`).
    public mutating func begin(count: Int) -> Bool {
        sheetPresented = false
        guard count > 0 else {
            running = false
            return false
        }
        running = true
        completed = 0
        total = count
        freed = 0
        failed = 0
        bannerVisible = false
        summaryPresented = false
        return workMayStart
    }

    public var workMayStart: Bool { !sheetPresented && running }

    public mutating func record(success: Bool, bytes: UInt64) {
        completed += 1
        if success {
            freed += bytes
        } else {
            failed += 1
        }
    }

    public mutating func finish() {
        running = false
        bannerVisible = true
        summaryPresented = false
    }

    public mutating func presentSummary() {
        summaryPresented = true
    }

    public mutating func dismissSummary() {
        summaryPresented = false
    }

    public mutating func dismissBanner() {
        bannerVisible = false
        summaryPresented = false
    }
}

public enum BatchPump {
    /// Runs `perform` for items that start before cancellation. Items not yet started are skipped.
    /// In-flight work is left to `perform`, which should watch `isCancelled` itself.
    @MainActor
    public static func run<Item: Sendable>(
        items: [Item],
        limit: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        perform: @escaping @MainActor (Item) async -> Void
    ) async -> (started: [Item], skipped: [Item]) {
        let cap = max(1, limit)
        var started: [Item] = []
        var index = 0
        var inflight: [Task<Void, Never>] = []
        while index < items.count || !inflight.isEmpty {
            if isCancelled() {
                let skipped = Array(items[index...])
                for job in inflight {
                    await job.value
                }
                return (started, skipped)
            }
            while inflight.count < cap, index < items.count, !isCancelled() {
                let item = items[index]
                index += 1
                started.append(item)
                inflight.append(Task { @MainActor in
                    await perform(item)
                })
            }
            if inflight.isEmpty { break }
            await inflight.removeFirst().value
        }
        return (started, [])
    }
}
