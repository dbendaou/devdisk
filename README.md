# DevDisk

DevDisk is a native macOS app for reclaiming space on a developer’s disk. The main screen is **Smart cleanup**: a catalogue of the folders toolchains, package managers, IDEs, simulators, and container engines actually leave behind. Each suggestion names the ecosystem, the size, whether it is safe to regenerate, and the exact action (move to Trash, or a tool’s own prune command).

A secondary **Explore** view is a squarified treemap and a size-sorted outline, for drilling into anything the rules do not name. It follows the same idea as [Disk Inventory X](https://github.com/diskinv/diskinv) (scan a folder, show a treemap, an outline, and a kind breakdown). The layout algorithm is an independent implementation of Bruls, Huizing, and van Wijk’s squarified treemaps. None of Disk Inventory X’s GPL code is copied. This project is MIT licensed.

Requires Apple Silicon and macOS 26 or later. The scanning, accounting, rule engine, and treemap layout live in the `DevDiskCore` library, which builds and tests on Linux and macOS. The SwiftUI app is macOS-only.

## Screens

**Smart cleanup** opens first after a scan. A stepper, “Projects untouched for N+ days” (default 30), filters per-project folders such as `node_modules`, `.next`, `target`, and `.venv`. Global caches are always listed. Suggestions are grouped by ecosystem (JavaScript, Apple, Editors, Python, Rust, Go, Java & Android, Ruby, Containers, Databases, Tools). A card shows the headline, the safety level, what the folder is, the action, and, for project folders, the project name, last-modified date, and size. Preview records what would happen. The real button opens a confirmation sheet that lists every path and the total size.

**Explore** is a Map / Files / Kinds switch. The map is a squarified treemap coloured by file kind. Click a block to select it; click a selected folder to zoom in, or a selected file to reveal it in Finder. Files is an outline sorted by size, name, kind, or date, with the same Reveal action. Kinds is the extension and kind breakdown.

The header shows the volume’s total, used, and free space, plus **estimated reclaimable**. Container prune cards are included as an upper bound (“up to N”) because `docker system prune` does not shrink the disk image to zero. `git gc` and `simctl delete unavailable` are shown with their on-disk size but are not added to the total, because they only reclaim part of it.

## Build and test

```sh
make test          # swift test, Linux or macOS
make app           # macOS only: dist/DevDisk.app, ad-hoc signed
open dist/DevDisk.app
```

`make app` uses Swift Command Line Tools (`swift build -c release --product DevDisk --arch arm64`), copies `App/Info.plist`, and runs `codesign --force --deep -s -`. No Xcode project is required. GitHub Actions runs the tests on Ubuntu and builds the app on macOS.

Scan your home folder for the full catalogue. A smaller folder only matches rules whose paths sit inside it.

## Catalogue

Rules are data in `CleanupCatalog`. Adding one is a new `RuleSpec`: an id, ecosystem, summary, safety level, a locator, and an effect. Earlier rules claim a path, so a file inside DerivedData is not also offered as a loose database file.

Per-project rules use the parent directory’s modification time (the project). The age stepper re-runs the engine without scanning again. Set it to 0 to include every project.

| Ecosystem | What it finds | Action | Safety |
| --- | --- | --- | --- |
| JavaScript | `node_modules`, `.next`, `.nuxt`, `.turbo`, `.parcel-cache` (past the age threshold, next to a project); `dist` next to `package.json` | Trash | Safe, except `dist` which is Review |
| JavaScript | npm, Yarn, pnpm, and Bun caches; `~/Library/pnpm` and `~/.pnpm-store` | Trash | Safe. The pnpm store is removed wholesale, not merely pruned |
| Apple | Xcode DerivedData, iOS/watchOS/tvOS DeviceSupport, CoreSimulator caches, SwiftPM caches (`org.swift.swiftpm`, `~/.cache/swiftpm`, `~/.cache/swifterpm`), CocoaPods, `.build` next to `Package.swift` | Trash | Safe |
| Apple | Xcode archives | Trash | Review |
| Apple | CoreSimulator Devices | `xcrun simctl delete unavailable` | Safe. Size is the whole Devices folder and is not added to the estimate |
| Editors | JetBrains caches and logs; VS Code and Cursor cache, CachedExtensions, and CachedExtensionVSIXs | Trash | Safe. Settings and `~/.cursor` chat data are not included |
| Python | pip, uv, Poetry, and Conda `pkgs` caches | Trash | Safe. Conda environments are not included |
| Python | `.venv`, `venv`, other folders with `pyvenv.cfg`, and `__pycache__`, past the age threshold | Trash | Virtualenvs are Review. Bytecode is Safe |
| Rust | `target/` next to `Cargo.toml`; `~/.cargo/registry` and `~/.cargo/git` | Trash | Safe. `~/.cargo/bin` is not included |
| Go | `~/go/pkg/mod`, `~/Library/Caches/go-build`, `~/.cache/go-build` | Trash | Safe |
| Java & Android | Gradle caches and daemon files | Trash | Safe |
| Java & Android | `~/.m2/repository`, Android SDK `system-images`, `~/.android/avd` | Trash | Review |
| Ruby | `~/.bundle/cache`, and `vendor/cache` in projects past the age threshold | Trash | Safe |
| Containers | Docker Desktop, OrbStack, Colima/Lima, Podman disk or storage | `docker system prune -af`, `colima ssh -- docker system prune -af`, or `podman system prune -af` | Review. The image file is never deleted. The size is an upper bound and is included in the estimate |
| Databases | Postgres (`PG_VERSION`), MySQL (`ibdata1`), MongoDB (`mongod.lock`), Redis dumps, SQLite/`.db` files of 50 MB or more | Trash | Always Review |
| Tools | Homebrew cache | Preview runs `brew cleanup -n -s`. Confirming runs `brew cleanup -s` | Safe |
| Tools | Playwright, Puppeteer, and Cypress browser caches; `~/.terraform.d/plugin-cache`; per-project `.terraform` next to a `.tf` file | Trash | Safe |
| Tools | `.log` files of 5 MB or more, past the age threshold | Trash | Review |
| Tools | `.git` directories of 50 MB or more, past the age threshold | `git gc --prune=now` in that repository | Review. The repository is not deleted. The size is not added to the estimate |

## Safety

- The default action is **Move to Trash** (`FileManager.trashItem`). Emptying Trash is not used; items stay recoverable until you empty Trash yourself.
- A confirmation sheet lists every path and the total before anything runs.
- **Preview** writes a log entry and does not delete. Homebrew’s preview is the exception: it runs `brew cleanup -n -s`, which only prints brew’s report.
- **Safe** means the bytes are regenerable (caches, build output, bytecode). **Review** means the folder may hold data: databases, archives, virtualenvs, Android images, `dist`, logs, or a container prune.
- Database rules are Review and never Safe.
- Nothing outside the scanned folder is touched. The scan root itself is never deleted.
- Refused even inside the scan: `/System`, `/usr`, `/bin`, `/sbin`, `/Library`, `/etc`, `/dev`, `/opt`, `/Applications`, `/private/etc`, `/private/var`, `~/Library/Keychains`, `~/Library/Mail`, and any Photos library (`.photoslibrary`).
- A folder is skipped if moving it to Trash would take a protected descendant with it.
- Tool commands are an allowlist of bare names (`brew`, `docker`, `podman`, `colima`, `xcrun`, `git`, …). The app does not invoke a shell. `git gc` is run once per repository with `git -C <repo>`.
- The scan uses allocated size (`st_blocks * 512`), not logical size. Symlinks are not followed. A hard link is counted once, on the lexicographically first path. The walk does not enter another volume. Permission errors are recorded and those folders are not suggested for cleanup.
- A log of previews and completed cleanups is kept in `~/Library/Application Support/DevDisk/removal-log.json`.

## What Linux CI checks

`make test` on Linux runs the library tests: allocated versus logical size (including a sparse file), symlink and hard-link accounting, permission errors, cancellation, not crossing a volume, the squarified layout, and the full cleanup catalogue against a temporary home directory plus a synthetic tree sized like a full disk (stale `node_modules` at 18.4 GB, JetBrains, Playwright, pnpm, Docker’s upper bound). Spotify, Steam, Downloads, Trash, and Claude app data are present as decoys and must not be suggested.

The SwiftUI app, Finder reveal, Trash, and `codesign` are not executed here. `make app` is what the macOS CI job runs.

## License

MIT. See [LICENSE](LICENSE).
