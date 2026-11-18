import Foundation
import Testing
@testable import DevDiskCore

struct CleanupTests {
    @Test func catalogIsADeveloperCatalogue() {
        let ids = CleanupCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let required = [
            "node-modules", "next-build", "nuxt-build", "turbo-cache", "parcel-cache", "js-dist",
            "npm-cache", "yarn-cache", "cache-pnpm", "bun-cache", "pnpm-library-store", "pnpm-dot-store",
            "xcode-derived-data", "xcode-archives", "xcode-device-support", "simulator-caches",
            "simulator-unavailable", "cache-swiftpm", "dotcache-swiftpm", "dotcache-swifterpm",
            "swiftpm-build", "cache-cocoapods",
            "cache-jetbrains", "jetbrains-logs", "vscode-caches", "cursor-caches",
            "pip-cache", "dotcache-uv", "poetry-cache", "conda-pkgs", "python-venv", "python-venv-marked", "pycache",
            "rust-target", "cargo-registry", "cargo-git",
            "go-modules", "go-build-cache",
            "gradle-caches", "gradle-daemons", "maven-repository", "android-system-images", "android-avds",
            "bundler-cache", "vendor-gem-cache",
            "docker-disk", "orbstack-disk", "colima-disk", "podman-disk",
            "postgres-data", "mysql-data", "mongo-data", "redis-dumps", "large-databases",
            "cache-homebrew", "cache-ms-playwright", "puppeteer-cache", "cypress-cache",
            "terraform-plugin-cache", "terraform-project", "project-logs", "git-gc",
        ]
        let present = Set(ids)
        for id in required {
            #expect(present.contains(id), "missing rule \(id)")
        }
        let dropped = ["cache-spotify", "cache-google", "steam-data", "downloads-large", "downloads-installers", "trash", "ai-claude", "ai-cursor", "ai-codex", "node-modules-recent"]
        for id in dropped {
            #expect(!present.contains(id), "\(id) should not be in the developer catalogue")
        }
        let databases = CleanupCatalog.all.filter { $0.ecosystem == .databases }
        #expect(!databases.isEmpty)
        #expect(databases.allSatisfy { $0.safety == .review })
    }

    @Test func exampleMachineFindsStaleProjectsAndSkipsTheRest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = ExampleMachine.make(now: now)
        let report = CleanupEngine().evaluate(root: root, now: now, staleAfterDays: 30)

        let stale = try! #require(report.suggestions.first { $0.ruleID == "node-modules" })
        #expect(stale.headline == "Remove 42 node_modules folders in projects untouched for 30+ days, 18.4 GB")
        #expect(stale.safety == .safe)
        #expect(stale.ecosystem == .javascript)
        #expect(stale.items.count == 42)
        let project = try! #require(stale.items.first { $0.projectName == "old-00" })
        #expect(project.lastModified == now.addingTimeInterval(-90 * 86_400))
        #expect(!stale.paths.contains { $0.hasSuffix("/new-app/node_modules") })

        expectSize(report, "cache-jetbrains", gb(160), .safe)
        expectSize(report, "cache-ms-playwright", gb(49), .safe)
        expectSize(report, "cache-pnpm", gb(9), .safe)
        expectSize(report, "pnpm-library-store", gb(95), .safe)
        expectSize(report, "pnpm-dot-store", gb(18), .safe)

        let docker = try! #require(report.suggestions.first { $0.ruleID == "docker-disk" })
        #expect(docker.countsTowardEstimate)
        #expect(docker.estimateIsUpperBound)
        #expect(docker.size == gb(93))
        if case .command(_, _, let display, _) = docker.effect {
            #expect(display == "docker system prune -af")
        } else {
            Issue.record("Docker should be a prune command")
        }

        let paths = report.suggestions.flatMap(\.paths)
        #expect(!paths.contains { $0.contains("Spotify") || $0.contains("Claude") || $0.contains("Steam") || $0.contains("Downloads") || $0.contains(".Trash") })
        #expect(!paths.contains { $0.contains("Keychains") || $0.contains(".photoslibrary") })
        #expect(report.skippedProtected.contains { $0.contains("Keychains") || $0.contains(".photoslibrary") })

        let counting = report.suggestions.filter(\.countsTowardEstimate).flatMap(\.paths).sorted()
        for (index, path) in counting.enumerated() {
            for other in counting.dropFirst(index + 1) {
                #expect(!other.hasPrefix(path + "/"), "\(other) is inside already counted \(path)")
            }
        }
        #expect(report.firmBytes + report.upperBoundBytes == report.estimatedReclaimableBytes)
        #expect(report.upperBoundBytes >= gb(93))
        let known = gb(160) + gb(49) + gb(9) + gb(95) + gb(18) + gb(184)
        #expect(report.firmBytes >= known)
        #expect(report.groups.contains { $0.ecosystem == .javascript && $0.suggestions.contains { $0.ruleID == "node-modules" } })

        let everything = CleanupEngine().evaluate(root: root, now: now, staleAfterDays: 0)
        let allModules = try! #require(everything.suggestions.first { $0.ruleID == "node-modules" })
        #expect(allModules.paths.contains { $0.hasSuffix("/new-app/node_modules") })
        #expect(allModules.headline.contains("in any project"))

        let ancient = CleanupEngine().evaluate(root: root, now: now, staleAfterDays: 100)
        #expect(!ancient.suggestions.contains { $0.ruleID == "node-modules" })
    }

    @Test func tempFixtureMatchesTheCatalogue() async throws {
        let root = try makeTemp()
        defer { remove(root) }
        try writeFixture(at: root)
        let tree = try await DirectoryScanner(maxConcurrentDirectories: 4).scan(root: root.path)
        let report = CleanupEngine().evaluate(root: tree.root, byteFloor: 1, staleAfterDays: 30)
        let ids = Set(report.suggestions.map(\.ruleID))
        let expected = [
            "node-modules", "next-build", "nuxt-build", "turbo-cache", "parcel-cache", "js-dist",
            "npm-cache", "yarn-cache", "cache-pnpm", "bun-cache", "pnpm-library-store", "pnpm-dot-store",
            "xcode-derived-data", "xcode-archives", "xcode-device-support", "simulator-caches",
            "simulator-unavailable", "cache-swiftpm", "dotcache-swiftpm", "dotcache-swifterpm",
            "swiftpm-build", "cache-cocoapods",
            "cache-jetbrains", "jetbrains-logs", "vscode-caches", "cursor-caches",
            "pip-cache", "dotcache-uv", "poetry-cache", "conda-pkgs", "python-venv", "python-venv-marked", "pycache",
            "rust-target", "cargo-registry", "cargo-git",
            "go-modules", "go-build-cache",
            "gradle-caches", "gradle-daemons", "maven-repository", "android-system-images", "android-avds",
            "bundler-cache", "vendor-gem-cache",
            "docker-disk", "orbstack-disk", "colima-disk", "podman-disk",
            "postgres-data", "mysql-data", "mongo-data", "redis-dumps", "large-databases",
            "cache-homebrew", "cache-ms-playwright", "puppeteer-cache", "cypress-cache",
            "terraform-plugin-cache", "terraform-project", "project-logs", "git-gc",
        ]
        for id in expected {
            #expect(ids.contains(id), "fixture missed \(id)")
        }
        let modules = try #require(report.suggestions.first { $0.ruleID == "node-modules" })
        #expect(modules.paths.contains { $0.hasSuffix("/old-app/node_modules") })
        #expect(!modules.paths.contains { $0.hasSuffix("/new-app/node_modules") })
        #expect(modules.items.contains { $0.projectName == "old-app" })
        let marked = try #require(report.suggestions.first { $0.ruleID == "python-venv-marked" })
        #expect(marked.paths.contains { $0.hasSuffix("/env") })
        #expect(!marked.paths.contains { $0.hasSuffix("/.venv") })
        let paths = report.suggestions.flatMap(\.paths)
        #expect(!paths.contains { $0.contains("Spotify") || $0.contains("Steam") || $0.contains("Claude") || $0.contains("Downloads") || $0.contains(".Trash") || $0.contains("Keychains") || $0.contains(".photoslibrary") })
    }

    @Test func newRulesAreData() {
        let root = ScanNode(
            id: 1, name: "dev", path: "/Users/dev", kind: .folder, allocatedSize: 5_000,
            isDirectory: true,
            children: [
                ScanNode(id: 2, name: "custom-cache", path: "/Users/dev/custom-cache", kind: .folder, allocatedSize: 5_000, isDirectory: true),
            ]
        )
        let rule = RuleSpec(
            id: "custom-cache",
            name: "Custom cache",
            summary: "A cache added without changing the engine.",
            ecosystem: .tools,
            safety: .safe,
            locator: .relativeDirectories(["custom-cache"])
        )
        let report = CleanupEngine().evaluate(root: root, rules: [rule], byteFloor: 1)
        #expect(report.suggestions.map(\.ruleID) == ["custom-cache"])
        #expect(report.suggestions[0].headline == "Clear Custom cache, 5 KB")
    }

    @Test func protectedDescendantBlocksTheParent() {
        let photos = ScanNode(
            id: 3, name: "Photos Library.photoslibrary", path: "/Users/dev/Projects/Photos Library.photoslibrary",
            kind: .folder, allocatedSize: 9_000, isDirectory: true
        )
        let projects = ScanNode(
            id: 2, name: "Projects", path: "/Users/dev/Projects", kind: .folder, allocatedSize: 9_000,
            isDirectory: true, children: [photos]
        )
        let root = ScanNode(
            id: 1, name: "dev", path: "/Users/dev", kind: .folder, allocatedSize: 9_000,
            isDirectory: true, children: [projects]
        )
        let rule = RuleSpec(
            id: "projects", name: "Projects", summary: "Everything under Projects.",
            ecosystem: .tools, safety: .review, locator: .relativeDirectories(["Projects"])
        )
        let report = CleanupEngine().evaluate(root: root, rules: [rule], byteFloor: 1)
        #expect(report.suggestions.isEmpty)
        #expect(report.skippedProtected.contains("/Users/dev/Projects"))
    }

    @Test func dryRunDoesNotCallThePerformer() throws {
        let suggestion = sampleSuggestion()
        let performer = RecordingPerformer()
        let record = try CleanupExecutor(performer: performer).execute(suggestion, scanRoot: "/Users/dev", dryRun: true)
        #expect(record.dryRun)
        #expect(record.succeeded)
        #expect(record.bytesFreed == 0)
        #expect(performer.trashed.isEmpty)
        #expect(performer.deleted.isEmpty)
        #expect(performer.commands.isEmpty)
        let copy = ConfirmationBuilder.make(suggestion, dryRun: true)
        #expect(copy.confirmTitle == "Record preview")
        #expect(copy.detail.contains("Nothing will be deleted"))
    }

    @Test func trashAndCommandExecution() throws {
        let suggestion = sampleSuggestion()
        let performer = RecordingPerformer()
        let record = try CleanupExecutor(performer: performer).execute(suggestion, scanRoot: "/Users/dev", dryRun: false)
        #expect(record.succeeded)
        #expect(record.bytesFreed == 300)
        #expect(performer.trashed == suggestion.paths)
        #expect(RemovalLog(records: [record]).totalFreedBytes == 300)

        let command = CleanupSuggestion(
            id: "docker-disk", ruleID: "docker-disk", name: "Docker unused data", summary: "prune",
            ecosystem: .containers,
            safety: .review,
            items: [CleanupPath(path: "/Users/dev/Library/Containers/com.docker.docker", bytes: 50)],
            headline: "Docker unused data, 50 B on disk",
            actionDescription: "Run docker system prune -af",
            effect: .command(executable: "docker", arguments: ["system", "prune", "-af"], display: "docker system prune -af", previewArguments: nil),
            countsTowardEstimate: true,
            estimateIsUpperBound: true
        )
        performer.trashed.removeAll()
        let ran = try CleanupExecutor(performer: performer).execute(command, scanRoot: "/Users/dev", dryRun: false)
        #expect(ran.succeeded)
        #expect(ran.bytesFreed == 0)
        #expect(performer.trashed.isEmpty)
        #expect(performer.commands == ["docker system prune -af"])
        let confirm = ConfirmationBuilder.make(command, dryRun: false)
        #expect(confirm.detail.contains("will not delete"))
        #expect(confirm.confirmTitle == "Run command")
    }

    @Test func homebrewPreviewRunsTheDryCommand() throws {
        let home = "/Users/dev"
        let root = directory("dev", home, [
            directory("Library", "\(home)/Library", [
                directory("Caches", "\(home)/Library/Caches", [
                    directory("Homebrew", "\(home)/Library/Caches/Homebrew", [
                        file("bottle.tar.gz", "\(home)/Library/Caches/Homebrew", 8_000),
                    ]),
                ]),
            ]),
        ])
        let report = CleanupEngine().evaluate(root: root, byteFloor: 1)
        let brew = try #require(report.suggestions.first { $0.ruleID == "cache-homebrew" })
        let performer = RecordingPerformer()
        let preview = try CleanupExecutor(performer: performer).execute(brew, scanRoot: home, dryRun: true)
        #expect(preview.dryRun)
        #expect(preview.succeeded)
        #expect(performer.commands == ["brew cleanup -n -s"])
        #expect(performer.trashed.isEmpty)
        performer.commands.removeAll()
        _ = try CleanupExecutor(performer: performer).execute(brew, scanRoot: home, dryRun: false)
        #expect(performer.commands == ["brew cleanup -s"])
        #expect(performer.trashed.isEmpty)
    }

    @Test func gitGcRunsInTheRepositoryAndDoesNotDeleteIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-90 * 86_400)
        let home = "/Users/dev"
        let root = directory("dev", home, [
            directory("repo", "\(home)/repo", [
                directory(".git", "\(home)/repo/.git", [
                    file("pack", "\(home)/repo/.git", 80_000_000),
                ]),
            ], modified: old),
        ])
        let report = CleanupEngine().evaluate(root: root, now: now, byteFloor: 1, staleAfterDays: 30)
        let git = try #require(report.suggestions.first { $0.ruleID == "git-gc" })
        #expect(git.estimateIsUpperBound)
        #expect(!git.countsTowardEstimate)
        #expect(git.items.first?.projectName == "repo")
        let performer = RecordingPerformer()
        let preview = try CleanupExecutor(performer: performer).execute(git, scanRoot: home, dryRun: true)
        #expect(preview.dryRun)
        #expect(performer.commands.isEmpty)
        _ = try CleanupExecutor(performer: performer).execute(git, scanRoot: home, dryRun: false)
        #expect(performer.commands == ["git -C \(home)/repo gc --prune=now"])
        #expect(performer.trashed.isEmpty)
    }

    @Test func safetyRefusalsHappenBeforeSideEffects() throws {
        let performer = RecordingPerformer()
        let executor = CleanupExecutor(performer: performer)
        let outside = forged(path: "/etc/passwd", effect: .moveToTrash)
        #expect(throws: SafetyViolation.outsideRoot("/etc/passwd")) {
            try executor.execute(outside, scanRoot: "/Users/dev", dryRun: false)
        }
        let keychain = forged(path: "/Users/dev/Library/Keychains/login.keychain-db", effect: .moveToTrash)
        #expect(throws: SafetyViolation.protected(Paths.normalize(keychain.paths[0]))) {
            try executor.execute(keychain, scanRoot: "/Users/dev", dryRun: false)
        }
        let root = forged(path: "/Users/dev", effect: .moveToTrash)
        #expect(throws: SafetyViolation.isScanRoot("/Users/dev")) {
            try executor.execute(root, scanRoot: "/Users/dev", dryRun: false)
        }
        let rm = CleanupSuggestion(
            id: "bad", ruleID: "bad", name: "bad", summary: "bad", safety: .review,
            items: [CleanupPath(path: "/Users/dev/x", bytes: 1)],
            headline: "bad", actionDescription: "Run rm -rf /",
            effect: .command(executable: "rm", arguments: ["-rf", "/"], display: "rm -rf /", previewArguments: nil),
            countsTowardEstimate: false
        )
        #expect(throws: SafetyViolation.commandNotAllowed("rm")) {
            try executor.execute(rm, scanRoot: "/Users/dev", dryRun: false)
        }
        let escaped = forged(path: "/Users/dev/../../etc/passwd", effect: .moveToTrash)
        #expect(throws: SafetyViolation.self) {
            try executor.execute(escaped, scanRoot: "/Users/dev", dryRun: false)
        }
        let notTrash = forged(path: "/Users/dev/notes.txt", effect: .emptyTrash)
        #expect(throws: SafetyViolation.notTrashChild("/Users/dev/notes.txt")) {
            try executor.execute(notTrash, scanRoot: "/Users/dev", dryRun: false)
        }
        #expect(performer.trashed.isEmpty)
        #expect(performer.deleted.isEmpty)
        #expect(performer.commands.isEmpty)
    }

    @Test func partialTrashStopsAndKeepsTheBytesAlreadyMoved() throws {
        let suggestion = sampleSuggestion()
        let performer = RecordingPerformer()
        performer.failAt = 2
        let record = try CleanupExecutor(performer: performer).execute(suggestion, scanRoot: "/Users/dev", dryRun: false)
        #expect(!record.succeeded)
        #expect(record.bytesFreed == 100)
        #expect(record.paths.count == 1)
        #expect(performer.trashed.count == 1)
    }

    @Test func pathNormalizationKeepsBoundaries() {
        #expect(Paths.isStrictlyInside("/Users/dev/Library", root: "/Users/dev"))
        #expect(!Paths.isStrictlyInside("/Users/developer", root: "/Users/dev"))
        #expect(PathSafety.isProtected("/usr/bin/swift"))
        #expect(PathSafety.isProtected("/Users/dev/Library/Keychains/login.keychain-db"))
        #expect(PathSafety.isProtected("/Users/dev/Library/Mail/V10/box"))
        #expect(PathSafety.isProtected("/Users/dev/Pictures/Photos Library.photoslibrary/Photos.sqlite"))
        #expect(!PathSafety.isProtected("/Users/dev/Library/Caches/JetBrains"))
        #expect(!PathSafety.isProtected("/tmp/devdisk-job"))
    }
}

private func expectSize(_ report: CleanupReport, _ id: String, _ size: UInt64, _ safety: SafetyLevel) {
    let match = report.suggestions.first { $0.ruleID == id }
    #expect(match?.size == size, "\(id) size \(match?.size ?? 0) != \(size)")
    #expect(match?.safety == safety)
}

private func gb(_ tenths: Int) -> UInt64 {
    UInt64(tenths) * 100_000_000
}

private func sampleSuggestion() -> CleanupSuggestion {
    CleanupSuggestion(
        id: "sample", ruleID: "sample", name: "Sample", summary: "Two files.",
        safety: .safe,
        items: [
            CleanupPath(path: "/Users/dev/a.bin", bytes: 100),
            CleanupPath(path: "/Users/dev/b.bin", bytes: 200),
        ],
        headline: "Clear Sample, 300 B",
        actionDescription: "Move 2 paths to Trash",
        effect: .moveToTrash,
        countsTowardEstimate: true
    )
}

private func forged(path: String, effect: CleanupEffect) -> CleanupSuggestion {
    CleanupSuggestion(
        id: "forged", ruleID: "forged", name: "forged", summary: "forged", safety: .review,
        items: [CleanupPath(path: path, bytes: 10)],
        headline: "forged", actionDescription: "forged", effect: effect,
        countsTowardEstimate: false
    )
}

final class RecordingPerformer: CleanupPerforming, @unchecked Sendable {
    private let lock = NSLock()
    var trashed: [String] = []
    var deleted: [String] = []
    var commands: [String] = []
    var failAt: Int?

    func moveToTrash(path: String) throws {
        try record(path, into: \.trashed)
    }

    func removePermanently(path: String) throws {
        try record(path, into: \.deleted)
    }

    func run(executable: String, arguments: [String]) throws -> String {
        lock.lock()
        commands.append(([executable] + arguments).joined(separator: " "))
        lock.unlock()
        return "ok"
    }

    private func record(_ path: String, into key: ReferenceWritableKeyPath<RecordingPerformer, [String]>) throws {
        lock.lock()
        defer { lock.unlock() }
        let next = self[keyPath: key].count + 1
        if failAt == next {
            throw CleanupFailure(message: "disk full")
        }
        self[keyPath: key].append(path)
    }
}

private enum ExampleMachine {
    static func make(now: Date) -> ScanNode {
        let home = "/Users/dev"
        let old = now.addingTimeInterval(-90 * 86_400)
        var projects: [ScanNode] = []
        var sizes = Array(repeating: UInt64(400_000_000), count: 41)
        sizes.append(2_000_000_000)
        for (index, size) in sizes.enumerated() {
            let name = String(format: "old-%02d", index)
            projects.append(project(name, home: home, modified: old, modules: size))
        }
        projects.append(project("new-app", home: home, modified: now, modules: gb(30)))
        let library = directory("Library", "\(home)/Library", [
            directory("Caches", "\(home)/Library/Caches", [
                cache("JetBrains", gb(160)),
                cache("ms-playwright", gb(49)),
                cache("pnpm", gb(9)),
                cache("Spotify", gb(20)),
            ]),
            directory("pnpm", "\(home)/Library/pnpm", [file("store", "\(home)/Library/pnpm", gb(95))]),
            directory("Application Support", "\(home)/Library/Application Support", [
                directory("Claude", "\(home)/Library/Application Support/Claude", [
                    file("state", "\(home)/Library/Application Support/Claude", gb(150)),
                ]),
                directory("Steam", "\(home)/Library/Application Support/Steam", [
                    file("games", "\(home)/Library/Application Support/Steam", gb(56)),
                ]),
            ]),
            directory("Containers", "\(home)/Library/Containers", [
                directory("com.docker.docker", "\(home)/Library/Containers/com.docker.docker", [
                    file("Docker.raw", "\(home)/Library/Containers/com.docker.docker", gb(93)),
                ]),
            ]),
            directory("Keychains", "\(home)/Library/Keychains", [
                file("login.keychain-db", "\(home)/Library/Keychains", gb(20)),
            ]),
        ])
        return directory("dev", home, [
            library,
            directory(".pnpm-store", "\(home)/.pnpm-store", [file("v3", "\(home)/.pnpm-store", gb(18))]),
            directory("Projects", "\(home)/Projects", projects),
            directory("Pictures", "\(home)/Pictures", [
                directory("Photos Library.photoslibrary", "\(home)/Pictures/Photos Library.photoslibrary", [
                    file("Photos.sqlite", "\(home)/Pictures/Photos Library.photoslibrary", gb(30)),
                ]),
            ]),
            directory("Downloads", "\(home)/Downloads", [file("App.dmg", "\(home)/Downloads", gb(20))]),
            directory(".Trash", "\(home)/.Trash", [file("old.log", "\(home)/.Trash", gb(5))]),
        ])
    }

    static func project(_ name: String, home: String, modified: Date, modules: UInt64) -> ScanNode {
        let path = "\(home)/Projects/\(name)"
        return directory(name, path, [
            file("package.json", path, 100),
            directory("node_modules", "\(path)/node_modules", [
                file("index.js", "\(path)/node_modules", modules),
            ]),
        ], modified: modified)
    }

    static func cache(_ name: String, _ size: UInt64) -> ScanNode {
        let parent = "/Users/dev/Library/Caches"
        return directory(name, "\(parent)/\(name)", [file("blob", "\(parent)/\(name)", size)])
    }
}

private func directory(_ name: String, _ path: String, _ children: [ScanNode], modified: Date? = nil) -> ScanNode {
    let size = children.reduce(UInt64(0)) { $0 + $1.allocatedSize }
    return ScanNode(
        id: path.hashValue, name: name, path: path, kind: .folder, allocatedSize: size,
        modified: modified, isDirectory: true, children: children
    )
}

private func file(_ name: String, _ parent: String, _ size: UInt64) -> ScanNode {
    ScanNode(
        id: (parent + name).hashValue, name: name, path: parent + "/" + name,
        kind: FileKind.classify(name: name), allocatedSize: size, logicalSize: size
    )
}

private func writeFixture(at root: URL) throws {
    let files = [
        "Library/Caches/JetBrains/a.bin",
        "Library/Logs/JetBrains/idea.log",
        "Library/Caches/ms-playwright/a.bin",
        "Library/Caches/puppeteer/a.bin",
        "Library/Caches/Cypress/a.bin",
        "Library/Caches/pnpm/a.bin",
        "Library/Caches/Yarn/a.bin",
        "Library/Caches/Homebrew/a.bin",
        "Library/Caches/org.swift.swiftpm/a.bin",
        "Library/Caches/CocoaPods/a.bin",
        "Library/Caches/pypoetry/a.bin",
        "Library/Caches/go-build/a.bin",
        "Library/Caches/Spotify/a.bin",
        "Library/pnpm/a.bin",
        ".pnpm-store/a.bin",
        ".npm/a.bin",
        ".bun/install/cache/a.bin",
        ".yarn/berry/cache/a.bin",
        ".cache/uv/a.bin",
        ".cache/pip/a.bin",
        ".cache/swiftpm/a.bin",
        ".cache/swifterpm/a.bin",
        ".cache/pypoetry/a.bin",
        ".cache/go-build/a.bin",
        ".cache/puppeteer/a.bin",
        ".gradle/caches/a.bin",
        ".gradle/daemon/daemon.log",
        ".m2/repository/a.bin",
        ".cargo/registry/a.bin",
        ".cargo/git/a.bin",
        ".bundle/cache/a.bin",
        ".terraform.d/plugin-cache/a.bin",
        ".conda/pkgs/a.bin",
        "go/pkg/mod/a.bin",
        "Library/Android/sdk/system-images/a.bin",
        ".android/avd/Pixel.avd/config.ini",
        "Library/Developer/Xcode/DerivedData/a.bin",
        "Library/Developer/Xcode/Archives/a.bin",
        "Library/Developer/Xcode/iOS DeviceSupport/a.bin",
        "Library/Developer/Xcode/watchOS DeviceSupport/a.bin",
        "Library/Developer/CoreSimulator/Caches/a.bin",
        "Library/Developer/CoreSimulator/Devices/DEV/a.bin",
        "Library/Containers/com.docker.docker/Data/Docker.raw",
        "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data.bin",
        ".colima/disk.img",
        ".local/share/containers/podman/machine/disk.img",
        "Library/Application Support/Code/Cache/a.bin",
        "Library/Application Support/Cursor/Cache/a.bin",
        "Library/Application Support/Cursor/CachedExtensions/ext.bin",
        "Library/Application Support/Claude/a.bin",
        "Library/Application Support/Steam/a.bin",
        "Projects/old-app/package.json",
        "Projects/old-app/node_modules/pkg/index.js",
        "Projects/old-app/.next/cache.bin",
        "Projects/old-app/.nuxt/x",
        "Projects/old-app/.turbo/x",
        "Projects/old-app/.parcel-cache/x",
        "Projects/old-app/dist/app.js",
        "Projects/old-app/vendor/cache/gem.tgz",
        "Projects/old-app/main.tf",
        "Projects/old-app/.terraform/providers/x",
        "Projects/old-app/debug.log",
        "Projects/new-app/node_modules/pkg/index.js",
        "Projects/rs/Cargo.toml",
        "Projects/rs/target/debug/app",
        "Projects/rs/.git/objects/pack",
        "Projects/sp/Package.swift",
        "Projects/sp/.build/debug/app",
        "Projects/py/.venv/pyvenv.cfg",
        "Projects/py/.venv/lib/x",
        "Projects/py/env/pyvenv.cfg",
        "Projects/py/pkg/__pycache__/m.pyc",
        "db/postgres/PG_VERSION",
        "db/mysql/ibdata1",
        "db/mongo/mongod.lock",
        "db/redis/dump.rdb",
        "db/app.sqlite",
        "Downloads/App.dmg",
        ".Trash/old.log",
        "Library/Keychains/login.keychain-db",
        "Pictures/Photos Library.photoslibrary/database/Photos.sqlite",
    ]
    for relative in files {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("devdisk".utf8).write(to: url)
    }
    for name in ["old-app", "rs", "sp", "py"] {
        try backdate(root.appendingPathComponent("Projects/\(name)"))
    }
}

private func backdate(_ url: URL) throws {
    var urls = [url]
    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let item as URL in enumerator {
            urls.append(item)
        }
    }
    urls.sort { $0.path.count > $1.path.count }
    let old = Date().addingTimeInterval(-90 * 86_400)
    for item in urls {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: item.path)
    }
}

private func makeTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("devdisk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
