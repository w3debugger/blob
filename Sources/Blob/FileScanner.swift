import Foundation

actor FileScanner {
    private static let skipDirs: Set<String> = [
        ".Trash", "Library/Caches", "node_modules", ".git",
        "Pods", ".build", "DerivedData", ".npm", ".cache"
    ]

    nonisolated private func isIgnored(_ path: String, ignoreList: [String]) -> Bool {
        for ig in ignoreList where !ig.isEmpty {
            if path == ig { return true }
            if path.hasPrefix(ig + "/") { return true }
        }
        return false
    }

    /// Curated developer-cache locations. Each is a *directory* whose total recursive
    /// size we report. Trashing the row trashes the whole directory — contents are
    /// regenerated next time the relevant tool runs.
    /// Strictly regenerable caches. Anything that holds user state (Xcode Archives /
    /// dSYMs, Docker/Colima/Lima/OrbStack VM disks with persistent volumes, Android SDK
    /// system images that require re-licensing) is intentionally excluded — losing those
    /// is data loss, not a cache wipe, and they don't belong in a "purge" preset.
    static func devJunkPaths() -> [URL] {
        let home = NSHomeDirectory()
        let rel: [String] = [
            // Xcode (excluded: Archives — irreplaceable dSYMs for shipped builds)
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/tvOS DeviceSupport",
            "Library/Developer/Xcode/UserData/IB Support",
            "Library/Developer/Xcode/UserData/Previews",
            "Library/Developer/CoreSimulator/Caches",
            "Library/Caches/com.apple.dt.Xcode",
            // JS / web
            ".npm/_cacache",
            "Library/Caches/Yarn",
            ".pnpm-store",
            "Library/pnpm/store",
            // Python
            "Library/Caches/pip",
            ".cache/pip",
            // JVM / Android (excluded: system-images — multi-GB redownload + EULA)
            ".gradle/caches",
            "Library/Caches/Google/AndroidStudio",
            // Rust / Go
            ".cargo/registry/cache",
            ".cargo/registry/src",
            "go/pkg/mod/cache",
            // Cocoa ecosystems
            "Library/Caches/CocoaPods",
            "Library/Caches/org.carthage.CarthageKit",
            // Editors
            "Library/Caches/JetBrains",
            "Library/Application Support/Code/Cache",
            "Library/Application Support/Code/CachedData",
            // Homebrew
            "Library/Caches/Homebrew",
            // Container/VM tools (excluded: docker/colima/lima/orbstack data dirs —
            // they hold persistent volumes & images, not caches)
        ]
        return rel.map { URL(fileURLWithPath: home).appendingPathComponent($0) }
    }

    func scanDevJunk(
        paths: [URL],
        ignoreList: [String],
        progress: @Sendable @escaping (String, Int, Int) -> Void
    ) async -> [BigFile] {
        let fm = FileManager.default
        var results: [BigFile] = []
        var scanned = 0
        for url in paths {
            if Task.isCancelled { break }
            scanned += 1
            if isIgnored(url.path, ignoreList: ignoreList) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            progress("sizing \(url.lastPathComponent)", scanned, results.count)
            let size = directorySize(url) { _ in }
            if Task.isCancelled { break }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            results.append(BigFile(url: url, size: size, modified: modified))
            progress(url.path, scanned, results.count)
        }
        return results.sorted { $0.size > $1.size }
    }

    nonisolated private func directorySize(
        _ url: URL,
        progress: @Sendable (String) -> Void
    ) -> Int64 {
        var total: Int64 = 0
        var lastReport = Date()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }
        while let next = enumerator.nextObject() {
            if Task.isCancelled { return total }
            guard let item = next as? URL else { continue }
            if let v = try? item.resourceValues(forKeys: Set(keys)),
               v.isSymbolicLink != true,
               v.isRegularFile == true,
               let size = v.fileSize {
                total += Int64(size)
            }
            if Date().timeIntervalSince(lastReport) > 0.1 {
                progress(item.path)
                lastReport = Date()
            }
        }
        return total
    }

    func scanDirs(
        root: URL,
        names: Set<String>,
        threshold: Int64,
        ignoreList: [String],
        progress: @Sendable @escaping (String, Int, Int) -> Void
    ) async -> [BigFile] {
        var results: [BigFile] = []
        var scannedCount = 0
        var lastReport = Date()

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        while let next = enumerator.nextObject() {
            if Task.isCancelled { break }
            guard let url = next as? URL else { continue }
            let path = url.path

            if isIgnored(path, ignoreList: ignoreList) {
                enumerator.skipDescendants()
                continue
            }

            scannedCount += 1

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isDirectory == true
            else { continue }

            if names.contains(url.lastPathComponent) {
                let scanned = scannedCount
                let found = results.count
                let total = directorySize(url) { sizingPath in
                    progress("sizing \(url.lastPathComponent) :: \(sizingPath)", scanned, found)
                }
                if Task.isCancelled { break }
                if total >= threshold {
                    results.append(BigFile(
                        url: url,
                        size: total,
                        modified: values.contentModificationDate ?? Date()
                    ))
                    progress(url.path, scannedCount, results.count)
                    lastReport = Date()
                }
                enumerator.skipDescendants()
            } else if Date().timeIntervalSince(lastReport) > 0.1 {
                progress(url.path, scannedCount, results.count)
                lastReport = Date()
            }
        }

        progress(root.path, scannedCount, results.count)
        return results.sorted { $0.size > $1.size }
    }

    func scan(
        root: URL,
        threshold: Int64,
        ignoreList: [String],
        progress: @Sendable @escaping (String, Int, Int) -> Void
    ) async -> [BigFile] {
        var results: [BigFile] = []
        var scannedCount = 0
        var lastReport = Date()

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        while let next = enumerator.nextObject() {
            if Task.isCancelled { break }
            guard let url = next as? URL else { continue }

            let path = url.path
            if Self.skipDirs.contains(where: { path.contains("/\($0)/") || path.hasSuffix("/\($0)") }) {
                enumerator.skipDescendants()
                continue
            }
            if isIgnored(path, ignoreList: ignoreList) {
                enumerator.skipDescendants()
                continue
            }

            scannedCount += 1

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  Int64(size) >= threshold
            else {
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    let display = url.deletingLastPathComponent().path
                    progress(display, scannedCount, results.count)
                    lastReport = Date()
                }
                continue
            }

            results.append(BigFile(
                url: url,
                size: Int64(size),
                modified: values.contentModificationDate ?? Date()
            ))

            if Date().timeIntervalSince(lastReport) > 0.1 {
                progress(url.deletingLastPathComponent().path, scannedCount, results.count)
                lastReport = Date()
            }
        }

        progress(root.path, scannedCount, results.count)
        return results.sorted { $0.size > $1.size }
    }
}
