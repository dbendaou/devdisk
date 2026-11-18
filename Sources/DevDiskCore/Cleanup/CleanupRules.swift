import Foundation

public enum Ecosystem: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    case javascript
    case apple
    case editors
    case python
    case rust
    case go
    case java
    case ruby
    case containers
    case databases
    case tools

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .javascript: "JavaScript"
        case .apple: "Apple"
        case .editors: "Editors"
        case .python: "Python"
        case .rust: "Rust"
        case .go: "Go"
        case .java: "Java & Android"
        case .ruby: "Ruby"
        case .containers: "Containers"
        case .databases: "Databases"
        case .tools: "Tools"
        }
    }

    public var subtitle: String {
        switch self {
        case .javascript: "Packages, stores, and framework build output"
        case .apple: "Xcode, simulators, and Swift packages"
        case .editors: "IDE and extension caches"
        case .python: "Environments, bytecode, and installer caches"
        case .rust: "Cargo output and the registry"
        case .go: "Module and build caches"
        case .java: "Gradle, Maven, and Android images"
        case .ruby: "Bundler and vendored gems"
        case .containers: "VM disk images, pruned with each tool's own command"
        case .databases: "Local data directories. Always Review."
        case .tools: "Homebrew, browsers, Terraform, logs, and git"
        }
    }
}

/// How a per-project rule decides which folders are old enough to suggest.
public enum AgeFilter: Sendable, Equatable {
    /// Ignore modification time. Used for global caches.
    case any
    /// The project (the parent directory) must be at least the user's threshold old.
    case olderThanThreshold
}

public enum ProjectAnchor: Sendable, Equatable {
    case none
    case parent
    case grandparent
}

public enum CleanupLocator: Sendable, Equatable {
    /// One or more paths relative to the scan root, grouped into a single card.
    case relativeDirectories([String])
    /// Each immediate child directory of a relative path becomes its own card.
    case childDirectories(under: String)
    /// Directories with one of `names`. Age is the parent directory's modification time.
    case directoriesNamed(
        names: [String],
        age: AgeFilter,
        siblingNamed: String?,
        siblingExtension: String?
    )
    /// A directory whose path ends with this relative suffix, such as `vendor/cache`.
    case directoriesEndingWith(String, age: AgeFilter)
    /// A directory whose immediate children include a file of this name (`PG_VERSION`, `mongod.lock`, …).
    case directoriesContainingFile(String, age: AgeFilter)
    /// Files, optionally under a relative directory. Empty `names` and `extensions` matches every file.
    case files(under: String?, names: [String], extensions: [String], largerThan: UInt64, age: AgeFilter)
}

public enum CleanupEffect: Sendable, Equatable {
    case moveToTrash
    case emptyTrash
    /// `previewArguments` is a non-destructive command used for Preview, such as `brew cleanup -n`.
    case command(executable: String, arguments: [String], display: String, previewArguments: [String]?)
    /// Run once per match. `{path}` is the matched path, or its parent when `usesParent` is set.
    case commandForEach(executable: String, arguments: [String], display: String, usesParent: Bool)

    public var displayLine: String {
        switch self {
        case .moveToTrash: "Move to Trash"
        case .emptyTrash: "Empty Trash"
        case .command(_, _, let display, _): display
        case .commandForEach(_, _, let display, _): display
        }
    }

    public var executableName: String? {
        switch self {
        case .command(let executable, _, _, _): executable
        case .commandForEach(let executable, _, _, _): executable
        case .moveToTrash, .emptyTrash: nil
        }
    }
}

public enum CleanupPhrasing: Sendable, Equatable {
    /// Qualifier may contain `{days}`, replaced with the user's age threshold.
    case removeCount(singular: String, plural: String, qualifier: String)
    case clearNamed
    case emptyTrash
    case toolPrune
}

public struct RuleSpec: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var ecosystem: Ecosystem
    public var safety: SafetyLevel
    public var locator: CleanupLocator
    public var effect: CleanupEffect
    public var phrasing: CleanupPhrasing
    public var minimumBytes: UInt64
    /// When false, the card is shown but its size is not added to the header estimate.
    public var countsTowardEstimate: Bool
    /// The measured size is an upper bound (a disk image, or a whole `.git`) rather than a precise reclaim.
    public var estimateIsUpperBound: Bool
    public var projectAnchor: ProjectAnchor

    public init(
        id: String,
        name: String,
        summary: String,
        ecosystem: Ecosystem,
        safety: SafetyLevel,
        locator: CleanupLocator,
        effect: CleanupEffect = .moveToTrash,
        phrasing: CleanupPhrasing = .clearNamed,
        minimumBytes: UInt64 = 1_000_000,
        countsTowardEstimate: Bool = true,
        estimateIsUpperBound: Bool = false,
        projectAnchor: ProjectAnchor = .none
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.ecosystem = ecosystem
        self.safety = safety
        self.locator = locator
        self.effect = effect
        self.phrasing = phrasing
        self.minimumBytes = minimumBytes
        self.countsTowardEstimate = countsTowardEstimate
        self.estimateIsUpperBound = estimateIsUpperBound
        self.projectAnchor = projectAnchor
    }
}

public struct CleanupPath: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var bytes: UInt64
    public var projectName: String?
    public var lastModified: Date?

    public init(path: String, bytes: UInt64, projectName: String? = nil, lastModified: Date? = nil) {
        self.path = path
        self.bytes = bytes
        self.projectName = projectName
        self.lastModified = lastModified
    }
}

public struct CleanupSuggestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var ruleID: String
    public var name: String
    public var summary: String
    public var ecosystem: Ecosystem
    public var safety: SafetyLevel
    public var items: [CleanupPath]
    public var headline: String
    public var actionDescription: String
    public var effect: CleanupEffect
    public var countsTowardEstimate: Bool
    public var estimateIsUpperBound: Bool

    public var paths: [String] { items.map(\.path) }
    public var size: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    public init(
        id: String,
        ruleID: String,
        name: String,
        summary: String,
        ecosystem: Ecosystem = .tools,
        safety: SafetyLevel,
        items: [CleanupPath],
        headline: String,
        actionDescription: String,
        effect: CleanupEffect,
        countsTowardEstimate: Bool,
        estimateIsUpperBound: Bool = false
    ) {
        self.id = id
        self.ruleID = ruleID
        self.name = name
        self.summary = summary
        self.ecosystem = ecosystem
        self.safety = safety
        self.items = items
        self.headline = headline
        self.actionDescription = actionDescription
        self.effect = effect
        self.countsTowardEstimate = countsTowardEstimate
        self.estimateIsUpperBound = estimateIsUpperBound
    }
}

public struct CleanupGroup: Sendable, Equatable, Identifiable {
    public var ecosystem: Ecosystem
    public var suggestions: [CleanupSuggestion]
    public var firmBytes: UInt64
    public var upperBoundBytes: UInt64

    public var id: String { ecosystem.rawValue }
    public var totalBytes: UInt64 { firmBytes + upperBoundBytes }

    public init(ecosystem: Ecosystem, suggestions: [CleanupSuggestion], firmBytes: UInt64, upperBoundBytes: UInt64) {
        self.ecosystem = ecosystem
        self.suggestions = suggestions
        self.firmBytes = firmBytes
        self.upperBoundBytes = upperBoundBytes
    }
}

public struct CleanupReport: Sendable, Equatable {
    public var suggestions: [CleanupSuggestion]
    public var estimatedReclaimableBytes: UInt64
    public var safeBytes: UInt64
    public var reviewBytes: UInt64
    /// Bytes we expect to free by moving files or scrubbing a cache.
    public var firmBytes: UInt64
    /// Bytes included in the estimate that are an upper bound, mostly container disk images.
    public var upperBoundBytes: UInt64
    public var skippedProtected: [String]

    public init(
        suggestions: [CleanupSuggestion],
        estimatedReclaimableBytes: UInt64,
        safeBytes: UInt64,
        reviewBytes: UInt64,
        firmBytes: UInt64 = 0,
        upperBoundBytes: UInt64 = 0,
        skippedProtected: [String]
    ) {
        self.suggestions = suggestions
        self.estimatedReclaimableBytes = estimatedReclaimableBytes
        self.safeBytes = safeBytes
        self.reviewBytes = reviewBytes
        self.firmBytes = firmBytes
        self.upperBoundBytes = upperBoundBytes
        self.skippedProtected = skippedProtected
    }

    public var groups: [CleanupGroup] {
        CleanupReport.groups(from: suggestions)
    }

    public static func groups(from suggestions: [CleanupSuggestion]) -> [CleanupGroup] {
        let ecosystems = Set(suggestions.map(\.ecosystem))
        return Ecosystem.allCases.compactMap { ecosystem in
            guard ecosystems.contains(ecosystem) else { return nil }
            let items = suggestions
                .filter { $0.ecosystem == ecosystem }
                .sorted { lhs, rhs in
                    if lhs.size != rhs.size { return lhs.size > rhs.size }
                    return lhs.id < rhs.id
                }
            let counting = items.filter(\.countsTowardEstimate)
            return CleanupGroup(
                ecosystem: ecosystem,
                suggestions: items,
                firmBytes: counting.filter { !$0.estimateIsUpperBound }.reduce(0) { $0 + $1.size },
                upperBoundBytes: counting.filter(\.estimateIsUpperBound).reduce(0) { $0 + $1.size }
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.ecosystem.rawValue < rhs.ecosystem.rawValue
        }
    }
}

public enum CleanupCatalog {
    /// Earlier rules claim a path first. Whole cache directories come before per-project
    /// folders, which come before individual database and log files.
    public static let all: [RuleSpec] = globalRules + projectRules + dataRules

    public static let defaultStaleDays = 30
    private static let cacheFloor: UInt64 = 1_000_000

    private static let globalRules: [RuleSpec] = [
        folder("npm-cache", "npm cache", .javascript, [".npm", "Library/Caches/npm"],
               "The npm download cache. The next install fills it again."),
        folder("yarn-cache", "Yarn cache", .javascript, ["Library/Caches/Yarn", ".yarn/berry/cache", ".yarn/cache"],
               "Package archives Yarn has already downloaded."),
        folder("cache-pnpm", "pnpm cache", .javascript, ["Library/Caches/pnpm"],
               "Tarballs pnpm keeps beside the content-addressed store."),
        folder("bun-cache", "Bun cache", .javascript, [".bun/install/cache"],
               "Packages cached by Bun."),
        folder("pnpm-library-store", "pnpm store", .javascript, ["Library/pnpm"],
               "The content-addressed store at ~/Library/pnpm. Projects fetch packages again on the next install. This removes the whole store, not only unreferenced packages."),
        folder("pnpm-dot-store", "pnpm store (dotfile)", .javascript, [".pnpm-store"],
               "The content-addressed store at ~/.pnpm-store."),
        folder("cache-swiftpm", "SwiftPM cache", .apple, ["Library/Caches/org.swift.swiftpm"],
               "Source archives Swift Package Manager has fetched."),
        folder("dotcache-swiftpm", "swiftpm cache", .apple, [".cache/swiftpm"],
               "Swift Package Manager checkouts under ~/.cache."),
        folder("dotcache-swifterpm", "swifterpm cache", .apple, [".cache/swifterpm"],
               "Cached Swift toolchains and package data under ~/.cache/swifterpm."),
        folder("cache-cocoapods", "CocoaPods cache", .apple, ["Library/Caches/CocoaPods"],
               "Pod archives. pod install downloads them again."),
        folder("xcode-derived-data", "Xcode DerivedData", .apple, ["Library/Developer/Xcode/DerivedData"],
               "Build products, indexes, and logs. Xcode recreates them on the next build."),
        RuleSpec(
            id: "xcode-archives",
            name: "Xcode archives",
            summary: "Archived app builds kept for distribution. Deleting one removes your ability to re-export that exact build.",
            ecosystem: .apple,
            safety: .review,
            locator: .relativeDirectories(["Library/Developer/Xcode/Archives"])
        ),
        folder("xcode-device-support", "Xcode device support", .apple, [
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/tvOS DeviceSupport",
        ], "Symbol files copied from devices. Xcode copies them again the next time you connect the device."),
        folder("simulator-caches", "Simulator caches", .apple, ["Library/Developer/CoreSimulator/Caches"],
               "CoreSimulator caches. The simulator recreates them."),
        RuleSpec(
            id: "simulator-unavailable",
            name: "Unavailable simulators",
            summary: "Runs xcrun simctl delete unavailable, which removes simulators whose runtime is no longer installed. The size shown is the whole Devices folder, an upper bound, so it is not added to the estimate. DevDisk does not delete the Devices folder.",
            ecosystem: .apple,
            safety: .safe,
            locator: .relativeDirectories(["Library/Developer/CoreSimulator/Devices"]),
            effect: .command(
                executable: "xcrun",
                arguments: ["simctl", "delete", "unavailable"],
                display: "xcrun simctl delete unavailable",
                previewArguments: nil
            ),
            phrasing: .toolPrune,
            countsTowardEstimate: false,
            estimateIsUpperBound: true
        ),
        folder("cache-jetbrains", "JetBrains caches", .editors, ["Library/Caches/JetBrains"],
               "IDE indexes, local history, and downloaded JDKs. Rebuilt the next time you open the IDE."),
        folder("jetbrains-logs", "JetBrains logs", .editors, ["Library/Logs/JetBrains"],
               "IDE log files. The next launch starts a new log."),
        folder("vscode-caches", "VS Code caches", .editors, [
            "Library/Application Support/Code/Cache",
            "Library/Application Support/Code/CachedData",
            "Library/Application Support/Code/CachedExtensions",
            "Library/Application Support/Code/CachedExtensionVSIXs",
            "Library/Application Support/Code/Code Cache",
            "Library/Application Support/Code/GPUCache",
            "Library/Application Support/Code - Insiders/Cache",
            "Library/Application Support/Code - Insiders/CachedExtensions",
            "Library/Application Support/Code - Insiders/CachedExtensionVSIXs",
        ], "Editor caches and downloaded extension packages. Settings and your extensions list stay put. VS Code rebuilds the caches."),
        folder("cursor-caches", "Cursor caches", .editors, [
            "Library/Application Support/Cursor/Cache",
            "Library/Application Support/Cursor/CachedData",
            "Library/Application Support/Cursor/CachedExtensions",
            "Library/Application Support/Cursor/CachedExtensionVSIXs",
            "Library/Application Support/Cursor/Code Cache",
            "Library/Application Support/Cursor/GPUCache",
        ], "Editor caches and downloaded extension packages. Chat history and settings under ~/.cursor are not touched."),
        folder("pip-cache", "pip cache", .python, [".cache/pip", "Library/Caches/pip"],
               "Wheels cached by pip."),
        folder("dotcache-uv", "uv cache", .python, [".cache/uv"],
               "Python wheels and builds cached by uv."),
        folder("poetry-cache", "Poetry cache", .python, [".cache/pypoetry", "Library/Caches/pypoetry"],
               "Wheels cached by Poetry."),
        folder("conda-pkgs", "Conda package cache", .python, [
            ".conda/pkgs", "miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs", "mambaforge/pkgs",
        ], "Downloaded Conda packages. Environments themselves are left alone."),
        folder("cargo-registry", "Cargo registry", .rust, [".cargo/registry"],
               "Crate sources Cargo has downloaded. The next build fetches them again. Installed binaries in ~/.cargo/bin are not included."),
        folder("cargo-git", "Cargo git checkouts", .rust, [".cargo/git"],
               "Git dependencies Cargo has cloned."),
        folder("go-modules", "Go module cache", .go, ["go/pkg/mod"],
               "Modules downloaded by Go. The next build downloads them again."),
        folder("go-build-cache", "Go build cache", .go, ["Library/Caches/go-build", ".cache/go-build"],
               "Compiled packages cached by the Go tool."),
        folder("gradle-caches", "Gradle caches", .java, [".gradle/caches"],
               "Downloaded Gradle dependencies and transforms."),
        folder("gradle-daemons", "Gradle daemons", .java, [".gradle/daemon"],
               "Gradle daemon registry and logs. The next build starts a new daemon."),
        RuleSpec(
            id: "maven-repository",
            name: "Maven repository",
            summary: "Artifacts in ~/.m2/repository. Most can be downloaded again. The folder can also hold private artifacts you installed with mvn install.",
            ecosystem: .java,
            safety: .review,
            locator: .relativeDirectories([".m2/repository"])
        ),
        RuleSpec(
            id: "android-system-images",
            name: "Android system images",
            summary: "Emulator system images under the Android SDK. They can be downloaded again from the SDK manager, and emulators that use them will not boot until you do.",
            ecosystem: .java,
            safety: .review,
            locator: .relativeDirectories(["Library/Android/sdk/system-images"])
        ),
        RuleSpec(
            id: "android-avds",
            name: "Android virtual devices",
            summary: "AVD definitions and snapshots in ~/.android/avd. Removing one deletes that emulator, including its saved state.",
            ecosystem: .java,
            safety: .review,
            locator: .relativeDirectories([".android/avd"])
        ),
        folder("bundler-cache", "Bundler cache", .ruby, [".bundle/cache"],
               "Gems Bundler has downloaded. The next bundle install fetches them again."),
        RuleSpec(
            id: "cache-homebrew",
            name: "Homebrew cache",
            summary: "Old Homebrew versions and cached downloads. Preview runs `brew cleanup -n -s`, which only prints brew's own estimate. Confirming runs `brew cleanup -s`. DevDisk does not delete the cache folder itself.",
            ecosystem: .tools,
            safety: .safe,
            locator: .relativeDirectories(["Library/Caches/Homebrew"]),
            effect: .command(
                executable: "brew",
                arguments: ["cleanup", "-s"],
                display: "brew cleanup -s",
                previewArguments: ["cleanup", "-n", "-s"]
            )
        ),
        folder("cache-ms-playwright", "Playwright browsers", .tools, ["Library/Caches/ms-playwright"],
               "Browser builds downloaded by Playwright. The next test run downloads what it needs."),
        folder("puppeteer-cache", "Puppeteer browsers", .tools, ["Library/Caches/puppeteer", ".cache/puppeteer"],
               "Browsers downloaded by Puppeteer."),
        folder("cypress-cache", "Cypress cache", .tools, ["Library/Caches/Cypress"],
               "Cypress binaries and browsers. The next Cypress run downloads them again."),
        folder("terraform-plugin-cache", "Terraform plugin cache", .tools, [".terraform.d/plugin-cache"],
               "Provider binaries shared across projects. terraform init downloads them again."),
        container(
            "docker-disk",
            "Docker unused data",
            ["Library/Containers/com.docker.docker"],
            "Docker Desktop's disk image. The action is docker system prune -af, which removes unused images, containers, and networks. DevDisk never deletes the disk image file. The size is an upper bound.",
            executable: "docker",
            arguments: ["system", "prune", "-af"],
            display: "docker system prune -af"
        ),
        container(
            "orbstack-disk",
            "OrbStack unused data",
            ["Library/Group Containers/HUAQ24HBR6.dev.orbstack", ".orbstack"],
            "OrbStack's data directory. The action is Docker's prune command, which OrbStack serves. DevDisk never deletes the disk image file. The size is an upper bound.",
            executable: "docker",
            arguments: ["system", "prune", "-af"],
            display: "docker system prune -af"
        ),
        container(
            "colima-disk",
            "Colima unused data",
            [".colima", ".lima"],
            "Colima or Lima disk images. The action prunes unused Docker data inside the VM. DevDisk never deletes the disk image file. The size is an upper bound.",
            executable: "colima",
            arguments: ["ssh", "--", "docker", "system", "prune", "-af"],
            display: "colima ssh -- docker system prune -af"
        ),
        container(
            "podman-disk",
            "Podman unused data",
            [".local/share/containers/podman", ".local/share/containers/storage"],
            "Podman's machine or storage. The action is podman system prune -af. DevDisk never deletes the disk image file. The size is an upper bound.",
            executable: "podman",
            arguments: ["system", "prune", "-af"],
            display: "podman system prune -af"
        ),
    ]

    private static let projectRules: [RuleSpec] = [
        projectRule(
            "node-modules", "Stale node_modules", .javascript,
            "Dependencies inside projects that have not been modified within the age you set. npm install, pnpm install, yarn, or bun install brings them back.",
            names: ["node_modules"],
            singular: "node_modules folder", plural: "node_modules folders"
        ),
        projectRule(
            "next-build", "Next.js build output", .javascript,
            ".next folders next to a package.json. next build or the dev server recreates them.",
            names: [".next"], sibling: "package.json",
            singular: ".next folder", plural: ".next folders"
        ),
        projectRule(
            "nuxt-build", "Nuxt build output", .javascript,
            ".nuxt folders next to a package.json. The next Nuxt build recreates them.",
            names: [".nuxt"], sibling: "package.json",
            singular: ".nuxt folder", plural: ".nuxt folders"
        ),
        projectRule(
            "turbo-cache", "Turborepo cache", .javascript,
            ".turbo folders next to a package.json. Turborepo rebuilds the cache.",
            names: [".turbo"], sibling: "package.json",
            singular: ".turbo folder", plural: ".turbo folders"
        ),
        projectRule(
            "parcel-cache", "Parcel cache", .javascript,
            ".parcel-cache folders next to a package.json.",
            names: [".parcel-cache"], sibling: "package.json",
            singular: "Parcel cache", plural: "Parcel caches"
        ),
        projectRule(
            "js-dist", "JavaScript dist output", .javascript,
            "dist folders next to a package.json. These are usually build output, but some projects commit or publish them, so this stays at Review.",
            names: ["dist"], sibling: "package.json",
            singular: "dist folder", plural: "dist folders",
            safety: .review
        ),
        projectRule(
            "swiftpm-build", "SwiftPM .build folders", .apple,
            "Local build output next to a Package.swift. swift build recreates it.",
            names: [".build"], sibling: "Package.swift",
            singular: ".build folder", plural: ".build folders"
        ),
        projectRule(
            "rust-target", "Rust target directories", .rust,
            "Cargo build output next to a Cargo.toml. cargo build recreates it.",
            names: ["target"], sibling: "Cargo.toml",
            singular: "target directory", plural: "target directories"
        ),
        projectRule(
            "python-venv", "Python virtualenvs", .python,
            "Folders named .venv or venv in projects that have not been modified within the age you set. They can be recreated from requirements, but they may contain editable installs.",
            names: [".venv", "venv"],
            singular: "virtualenv", plural: "virtualenvs",
            safety: .review
        ),
        RuleSpec(
            id: "python-venv-marked",
            name: "Other Python virtualenvs",
            summary: "Directories containing pyvenv.cfg that are not named .venv, in projects past the age threshold. They may contain editable installs.",
            ecosystem: .python,
            safety: .review,
            locator: .directoriesContainingFile("pyvenv.cfg", age: .olderThanThreshold),
            phrasing: .removeCount(singular: "virtualenv", plural: "virtualenvs", qualifier: " in projects untouched for {days}+ days"),
            projectAnchor: .parent
        ),
        projectRule(
            "pycache", "Python bytecode", .python,
            "__pycache__ folders. Python recreates them on the next import.",
            names: ["__pycache__"],
            singular: "__pycache__ folder", plural: "__pycache__ folders"
        ),
        projectRule(
            "terraform-project", "Terraform providers", .tools,
            ".terraform folders next to a .tf file, in projects past the age threshold. terraform init downloads providers again.",
            names: [".terraform"], siblingExtension: "tf",
            singular: ".terraform folder", plural: ".terraform folders"
        ),
        RuleSpec(
            id: "vendor-gem-cache",
            name: "Vendored gem cache",
            summary: "vendor/cache directories in projects past the age threshold. bundle install can fetch the gems again.",
            ecosystem: .ruby,
            safety: .safe,
            locator: .directoriesEndingWith("vendor/cache", age: .olderThanThreshold),
            phrasing: .removeCount(singular: "gem cache", plural: "gem caches", qualifier: " in projects untouched for {days}+ days"),
            projectAnchor: .grandparent
        ),
        RuleSpec(
            id: "git-gc",
            name: "Large Git repositories",
            summary: "Projects past the age threshold whose .git directory is at least 50 MB. The action is git gc --prune=now in each repository. DevDisk does not delete the repository. The size is the whole .git directory, an upper bound on what packing might free, so it is not added to the estimate.",
            ecosystem: .tools,
            safety: .review,
            locator: .directoriesNamed(names: [".git"], age: .olderThanThreshold, siblingNamed: nil, siblingExtension: nil),
            effect: .commandForEach(
                executable: "git",
                arguments: ["-C", "{path}", "gc", "--prune=now"],
                display: "git gc --prune=now",
                usesParent: true
            ),
            phrasing: .toolPrune,
            minimumBytes: 50_000_000,
            countsTowardEstimate: false,
            estimateIsUpperBound: true,
            projectAnchor: .parent
        ),
    ]

    private static let dataRules: [RuleSpec] = [
        RuleSpec(
            id: "postgres-data",
            name: "Postgres data directories",
            summary: "Directories containing PG_VERSION. This is the database itself, not a cache.",
            ecosystem: .databases,
            safety: .review,
            locator: .directoriesContainingFile("PG_VERSION", age: .any)
        ),
        RuleSpec(
            id: "mysql-data",
            name: "MySQL data directories",
            summary: "Directories containing ibdata1. This is the database itself, not a cache.",
            ecosystem: .databases,
            safety: .review,
            locator: .directoriesContainingFile("ibdata1", age: .any)
        ),
        RuleSpec(
            id: "mongo-data",
            name: "MongoDB data directories",
            summary: "Directories containing mongod.lock. This is the database itself, not a cache.",
            ecosystem: .databases,
            safety: .review,
            locator: .directoriesContainingFile("mongod.lock", age: .any)
        ),
        RuleSpec(
            id: "redis-dumps",
            name: "Redis dumps",
            summary: "dump.rdb and appendonly.aof files. These are database snapshots.",
            ecosystem: .databases,
            safety: .review,
            locator: .files(under: nil, names: ["dump.rdb", "appendonly.aof"], extensions: [], largerThan: 1_000_000, age: .any)
        ),
        RuleSpec(
            id: "large-databases",
            name: "Large database files",
            summary: "SQLite and .db files of 50 MB or more that were not already included in another suggestion. They may be app data.",
            ecosystem: .databases,
            safety: .review,
            locator: .files(under: nil, names: [], extensions: ["sqlite", "sqlite3", "db"], largerThan: 50_000_000, age: .any),
            minimumBytes: 50_000_000
        ),
        RuleSpec(
            id: "project-logs",
            name: "Old project logs",
            summary: "Log files of 5 MB or more in projects past the age threshold. Logs can be the only record of a failure, so this stays at Review.",
            ecosystem: .tools,
            safety: .review,
            locator: .files(under: nil, names: [], extensions: ["log"], largerThan: 5_000_000, age: .olderThanThreshold),
            phrasing: .removeCount(singular: "log file", plural: "log files", qualifier: " untouched for {days}+ days"),
            minimumBytes: 5_000_000,
            projectAnchor: .parent
        ),
    ]

    private static func folder(
        _ id: String,
        _ name: String,
        _ ecosystem: Ecosystem,
        _ paths: [String],
        _ summary: String
    ) -> RuleSpec {
        RuleSpec(
            id: id,
            name: name,
            summary: summary,
            ecosystem: ecosystem,
            safety: .safe,
            locator: .relativeDirectories(paths)
        )
    }

    private static func container(
        _ id: String,
        _ name: String,
        _ paths: [String],
        _ summary: String,
        executable: String,
        arguments: [String],
        display: String
    ) -> RuleSpec {
        RuleSpec(
            id: id,
            name: name,
            summary: summary,
            ecosystem: .containers,
            safety: .review,
            locator: .relativeDirectories(paths),
            effect: .command(executable: executable, arguments: arguments, display: display, previewArguments: nil),
            phrasing: .toolPrune,
            estimateIsUpperBound: true
        )
    }

    private static func projectRule(
        _ id: String,
        _ name: String,
        _ ecosystem: Ecosystem,
        _ summary: String,
        names: [String],
        sibling: String? = nil,
        siblingExtension: String? = nil,
        singular: String,
        plural: String,
        safety: SafetyLevel = .safe
    ) -> RuleSpec {
        RuleSpec(
            id: id,
            name: name,
            summary: summary,
            ecosystem: ecosystem,
            safety: safety,
            locator: .directoriesNamed(
                names: names,
                age: .olderThanThreshold,
                siblingNamed: sibling,
                siblingExtension: siblingExtension
            ),
            phrasing: .removeCount(
                singular: singular,
                plural: plural,
                qualifier: " in projects untouched for {days}+ days"
            ),
            projectAnchor: .parent
        )
    }
}
