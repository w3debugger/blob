import SwiftUI
import AppKit

private let ignoreListKey = "blob.ignoreList"
private let dirNamesKey = "blob.dirNames"
private let dirNamesSeenKey = "blob.dirNames.seenDefaults"
private let rowHeight: CGFloat = 24

private let defaultDirNames = [
    // JS / web build outputs
    "node_modules", "bower_components",
    "dist", "build", "out",
    ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache",
    ".angular", ".cache",
    // Native / mobile
    "DerivedData", ".build", "Pods", "Carthage",
    "target",          // Rust, Java, Maven
    ".gradle",         // Gradle
    // Python
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
    "venv", ".venv",
    // Other
    "vendor",          // Go, Composer, Ruby
    ".terraform",      // Terraform plugins (often hundreds of MB)
    ".idea"            // JetBrains caches
]

@MainActor
final class AppModel: ObservableObject {
    @Published var rootPath: String = NSHomeDirectory()
    @Published var threshold: SizeFilter = .mb100
    @Published var mode: ScanMode = .files
    @Published var state: ScanState = .idle
    @Published var files: [BigFile] = [] {
        didSet { rebuildVisible() }
    }
    @Published var selection: Set<BigFile.ID> = [] {
        didSet { recomputeTotals() }
    }
    @Published var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            focusedIndex = 0
            rebuildVisible()
        }
    }
    @Published var log: [String] = []
    @Published var focusedIndex: Int = 0
    @Published var showIgnoreSheet: Bool = false
    @Published var showDirNamesSheet: Bool = false
    @Published var showShortcutsSheet: Bool = false
    @Published var searchFocusToken: Int = 0

    @Published private(set) var visibleFiles: [BigFile] = []
    @Published private(set) var totalSize: Int64 = 0
    @Published private(set) var selectedSize: Int64 = 0

    private func rebuildVisible() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        visibleFiles = q.isEmpty
            ? files
            : files.filter { $0.path.lowercased().contains(q) }

        let visibleIds = Set(visibleFiles.map(\.id))
        let pruned = selection.intersection(visibleIds)
        if pruned != selection {
            selection = pruned // triggers recomputeTotals via didSet
        } else {
            recomputeTotals()
        }
    }

    private func recomputeTotals() {
        var t: Int64 = 0
        var s: Int64 = 0
        for f in visibleFiles {
            t += f.size
            if selection.contains(f.id) { s += f.size }
        }
        totalSize = t
        selectedSize = s
    }

    @Published var ignoreList: [String] {
        didSet { UserDefaults.standard.set(ignoreList, forKey: ignoreListKey) }
    }

    @Published var dirNames: [String] {
        didSet { UserDefaults.standard.set(dirNames, forKey: dirNamesKey) }
    }

    private enum DragMode { case select, deselect }
    private var dragMode: DragMode?
    private var dragInitialSelection: Set<BigFile.ID>?

    private let scanner: FileScanner
    private var task: Task<Void, Never>?

    init() {
        let scanner = FileScanner()
        self.scanner = scanner

        self.ignoreList = UserDefaults.standard.stringArray(forKey: ignoreListKey) ?? []

        let defaults = UserDefaults.standard

        let saved = defaults.stringArray(forKey: dirNamesKey)
        if let saved {
            // Add any *new* defaults the user hasn't been offered before.
            // Removals the user made stick because those names are in `seen`.
            let seen = Set(defaults.stringArray(forKey: dirNamesSeenKey) ?? [])
            let current = Set(saved)
            var merged = saved
            for name in defaultDirNames where !seen.contains(name) && !current.contains(name) {
                merged.append(name)
            }
            self.dirNames = merged
        } else {
            self.dirNames = defaultDirNames
        }
        defaults.set(defaultDirNames, forKey: dirNamesSeenKey)
    }

    func appendLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(stamp)] \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func startScan() {
        task?.cancel()
        let url = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath)
        files = []
        selection = []
        focusedIndex = 0
        state = .scanning(path: url.path, scanned: 0, found: 0)
        let mode = self.mode
        let usesThreshold = mode == .files
        let thresholdLabel = usesThreshold ? threshold.label : "any"
        appendLog("scan start :: \(url.path) mode=\(mode.label) threshold=\(thresholdLabel) ignored=\(ignoreList.count)")
        let started = Date()
        let threshold: Int64 = usesThreshold ? self.threshold.bytes : 0
        let ignore = self.ignoreList
        let names = Set(self.dirNames)
        task = Task.detached { [scanner] in
            let results: [BigFile]
            switch mode {
            case .files:
                results = await scanner.scan(
                    root: url,
                    threshold: threshold,
                    ignoreList: ignore
                ) { path, scanned, found in
                    Task { @MainActor in
                        if case .scanning = self.state {
                            self.state = .scanning(path: path, scanned: scanned, found: found)
                        }
                    }
                }
            case .dirs:
                results = await scanner.scanDirs(
                    root: url,
                    names: names,
                    threshold: threshold,
                    ignoreList: ignore
                ) { path, scanned, found in
                    Task { @MainActor in
                        if case .scanning = self.state {
                            self.state = .scanning(path: path, scanned: scanned, found: found)
                        }
                    }
                }
            case .devjunk:
                results = await scanner.scanDevJunk(
                    paths: FileScanner.devJunkPaths(),
                    ignoreList: ignore
                ) { path, scanned, found in
                    Task { @MainActor in
                        if case .scanning = self.state {
                            self.state = .scanning(path: path, scanned: scanned, found: found)
                        }
                    }
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                let elapsed = Date().timeIntervalSince(started)
                self.files = results
                self.state = .done(total: results.count, scanned: results.count, elapsed: elapsed)
                let kind: String
                switch mode {
                case .files:   kind = "file\(results.count == 1 ? "" : "s")"
                case .dirs:    kind = "director\(results.count == 1 ? "y" : "ies")"
                case .devjunk: kind = "dev cache\(results.count == 1 ? "" : "s")"
                }
                self.appendLog("scan done :: \(results.count) \(kind) in \(String(format: "%.2f", elapsed))s")
            }
        }
    }

    func cancelScan() {
        task?.cancel()
        appendLog("scan cancelled")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath)
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
            appendLog("root :: \(url.path)")
        }
    }

    func reveal(_ file: BigFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func trashSelected() {
        let toDelete = files.filter { selection.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        let alert = NSAlert()
        let messageText: String
        let primaryButton: String
        switch mode {
        case .dirs:
            let plural = toDelete.count == 1 ? "y" : "ies"
            messageText = "Move \(toDelete.count) director\(plural) to Trash?"
            primaryButton = "Move to Trash"
        case .devjunk:
            let plural = toDelete.count == 1 ? "y" : "ies"
            messageText = "Delete \(toDelete.count) developer cache director\(plural)?"
            primaryButton = "Move to Trash"
        case .files:
            let plural = toDelete.count == 1 ? "" : "s"
            messageText = "Move \(toDelete.count) file\(plural) to Trash?"
            primaryButton = "Move to Trash"
        }
        alert.messageText = messageText
        let totalText = "Total: \(formatBytes(toDelete.reduce(0) { $0 + $1.size }))"
        alert.informativeText = totalText
        alert.alertStyle = .warning
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashed: [BigFile.ID] = []
        var freed: Int64 = 0
        for f in toDelete {
            do {
                try FileManager.default.trashItem(at: f.url, resultingItemURL: nil)
                trashed.append(f.id)
                freed += f.size
                appendLog("trash :: \(f.path)")
            } catch {
                appendLog("error :: \(f.name) — \(error.localizedDescription)")
            }
        }
        files.removeAll { trashed.contains($0.id) }
        selection.removeAll()
        focusedIndex = min(focusedIndex, max(0, visibleFiles.count - 1))
        appendLog("freed :: \(formatBytes(freed))")
    }

    func selectAll() { selection = Set(visibleFiles.map(\.id)) }
    func deselectAll() { selection.removeAll() }
    func toggleAll() {
        if selection.count == visibleFiles.count && !visibleFiles.isEmpty {
            deselectAll()
        } else {
            selectAll()
        }
    }

    func toggleFocused() {
        guard visibleFiles.indices.contains(focusedIndex) else { return }
        let id = visibleFiles[focusedIndex].id
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func moveFocus(_ delta: Int) {
        guard !visibleFiles.isEmpty else { return }
        focusedIndex = max(0, min(visibleFiles.count - 1, focusedIndex + delta))
    }

    func focusFirst() {
        guard !visibleFiles.isEmpty else { return }
        focusedIndex = 0
    }

    func focusLast() {
        guard !visibleFiles.isEmpty else { return }
        focusedIndex = visibleFiles.count - 1
    }

    func revealFocused() {
        guard visibleFiles.indices.contains(focusedIndex) else { return }
        reveal(visibleFiles[focusedIndex])
    }

    /// Trash whatever is selected; if nothing is selected, fall back to the focused row.
    func trashShortcut() {
        if !selection.isEmpty {
            trashSelected()
        } else if visibleFiles.indices.contains(focusedIndex) {
            selection = [visibleFiles[focusedIndex].id]
            trashSelected()
        }
    }

    func requestSearchFocus() {
        searchFocusToken &+= 1
    }

    func addToIgnoreList(_ path: String) {
        guard !ignoreList.contains(path) else { return }
        ignoreList.append(path)
        appendLog("ignore + :: \(path)")
        files.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        selection = selection.intersection(Set(files.map(\.id)))
        focusedIndex = min(focusedIndex, max(0, visibleFiles.count - 1))
    }

    func ignoreSelected() {
        let toIgnore = files.filter { selection.contains($0.id) }.map(\.path)
        guard !toIgnore.isEmpty else { return }
        for path in toIgnore where !ignoreList.contains(path) {
            ignoreList.append(path)
        }
        appendLog("ignore + :: \(toIgnore.count) path\(toIgnore.count == 1 ? "" : "s")")
        let ignoreSet = Set(toIgnore)
        files.removeAll { ignoreSet.contains($0.path) }
        selection.removeAll()
        focusedIndex = min(focusedIndex, max(0, visibleFiles.count - 1))
    }

    func removeFromIgnoreList(_ path: String) {
        ignoreList.removeAll { $0 == path }
        appendLog("ignore - :: \(path)")
    }

    func addDirName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !dirNames.contains(trimmed) else { return }
        dirNames.append(trimmed)
        appendLog("dirname + :: \(trimmed)")
    }

    func removeDirName(_ name: String) {
        dirNames.removeAll { $0 == name }
        appendLog("dirname - :: \(name)")
    }

    func resetDirNames() {
        dirNames = defaultDirNames
        appendLog("dirnames :: reset to defaults")
    }

    func dragHitRange(start: Int, end: Int) {
        guard !visibleFiles.isEmpty else { return }
        let startIdx = max(0, min(visibleFiles.count - 1, start))
        let endIdx = max(0, min(visibleFiles.count - 1, end))
        if dragMode == nil {
            dragInitialSelection = selection
            let anchorId = visibleFiles[startIdx].id
            dragMode = selection.contains(anchorId) ? .deselect : .select
        }
        guard let mode = dragMode, let initial = dragInitialSelection else { return }
        let lo = min(startIdx, endIdx)
        let hi = max(startIdx, endIdx)
        var newSel = initial
        for i in lo...hi {
            let id = visibleFiles[i].id
            switch mode {
            case .select: newSel.insert(id)
            case .deselect: newSel.remove(id)
            }
        }
        selection = newSel
        focusedIndex = endIdx
    }

    func endDrag() {
        dragMode = nil
        dragInitialSelection = nil
    }

}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showLog = false

    var body: some View {
        ZStack {
            MatrixRain().opacity(0.18)

            VStack(spacing: 0) {
                CompactHeader(model: model, showLog: $showLog)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                separator

                ConfigPanel(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                separator

                FileTable(model: model)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                separator

                ActionBar(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                if showLog {
                    separator
                    LogView(lines: model.log)
                        .frame(height: 120)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        }
        .background(Color.black)
        .font(.system(.body, design: .monospaced))
        .foregroundColor(.green)
        .sheet(isPresented: $model.showIgnoreSheet) { IgnoreListSheet(model: model) }
        .sheet(isPresented: $model.showDirNamesSheet) { DirNamesSheet(model: model) }
        .sheet(isPresented: $model.showShortcutsSheet) { ShortcutsSheet(model: model) }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.green.opacity(0.25))
            .frame(height: 1)
    }
}

// MARK: - Header

private struct CompactHeader: View {
    @ObservedObject var model: AppModel
    @Binding var showLog: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("BLOB")
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .foregroundColor(.green)
            Text("▌")
                .font(.system(size: 18, weight: .light, design: .monospaced))
                .foregroundColor(.green.opacity(0.4))
            Text("disk reaper")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.green.opacity(0.7))

            Spacer()

            Text(modeHint)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green.opacity(0.5))
                .lineLimit(1)

            TermButton(label: "?") { model.showShortcutsSheet = true }
                .help("Show keyboard shortcuts")
            TermButton(label: showLog ? "log ▴" : "log ▾") { showLog.toggle() }
                .help(showLog ? "Hide activity log" : "Show activity log")
        }
    }

    private var modeHint: String {
        switch model.mode {
        case .files:   return "// hunting big individual files · press ? for shortcuts"
        case .dirs:    return "// hunting big directories by name · press ? for shortcuts"
        case .devjunk: return "// sweeping developer caches · all regenerable"
        }
    }
}

// MARK: - Config panel

private struct ConfigPanel: View {
    @ObservedObject var model: AppModel

    private func fixedRootHint(for mode: ScanMode) -> String {
        switch mode {
        case .devjunk: return "developer caches (Xcode, simulators, npm, gradle, brew…)"
        default:       return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Labeled("mode") {
                    ModeToggle(selection: $model.mode)
                }
                if model.mode == .files {
                    Labeled("size") {
                        TermPicker(
                            selection: $model.threshold,
                            options: SizeFilter.allCases,
                            label: { $0.label }
                        )
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("$").foregroundColor(.green.opacity(0.6))
                if model.mode == .devjunk {
                    Text(fixedRootHint(for: model.mode))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.green.opacity(0.6))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    TextField("path", text: $model.rootPath)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.green.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.green.opacity(0.5), lineWidth: 1)
                        )
                    TermButton(label: "browse") { model.chooseFolder() }
                }
                if case .scanning = model.state {
                    TermButton(label: "stop", danger: true) { model.cancelScan() }
                } else {
                    TermButton(label: "scan") { model.startScan() }
                }
            }

            if model.mode == .dirs {
                NamesChips(model: model)
            }
        }
    }
}

private struct Labeled<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.green.opacity(0.5))
            content()
        }
    }
}

private struct ModeToggle: View {
    @Binding var selection: ScanMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ScanMode.allCases) { mode in
                ModeToggleButton(
                    label: mode.label,
                    active: mode == selection
                ) { selection = mode }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.green.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct ModeToggleButton: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .frame(minWidth: 60)
                .foregroundColor(active ? .black : .green)
                .background(background)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if active {
            Color.green
        } else if hover {
            Color.green.opacity(0.15)
        } else {
            Color.clear
        }
    }
}

private struct NamesChips: View {
    @ObservedObject var model: AppModel
    private let previewCount = 6

    var body: some View {
        let preview = Array(model.dirNames.prefix(previewCount))
        let remaining = model.dirNames.count - preview.count
        HStack(spacing: 6) {
            Text("WATCHING")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.green.opacity(0.5))
            ForEach(preview, id: \.self) { name in
                Chip(label: name)
            }
            if remaining > 0 {
                Text("+\(remaining)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green.opacity(0.6))
            }
            if model.dirNames.isEmpty {
                Text("// no names configured")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red.opacity(0.7))
            }
            Spacer()
            TermButton(label: "edit") { model.showDirNamesSheet = true }
        }
    }
}

private struct Chip: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, design: .monospaced))
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .foregroundColor(.green)
            .background(Color.green.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.green.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @ObservedObject var model: AppModel

    private var trashLabel: String {
        switch model.mode {
        case .devjunk: return "purge"
        default:       return "trash"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusText(model: model)
            Spacer()
            TermButton(label: "ignored [\(model.ignoreList.count)]") {
                model.showIgnoreSheet = true
            }
            TermButton(
                label: "ignore [\(model.selection.count)]",
                disabled: model.selection.isEmpty
            ) { model.ignoreSelected() }
            TermButton(
                label: "\(trashLabel) [\(model.selection.count)]",
                danger: true,
                disabled: model.selection.isEmpty
            ) { model.trashSelected() }
        }
    }
}

private struct StatusText: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .idle:
                Text("> ready. press [scan] to begin.")
            case .scanning(let path, let scanned, let found):
                BlinkingCursor()
                Text("scanning \(scanned) · found \(found) · \(truncate(path, max: 50))")
                    .lineLimit(1)
            case .done(let total, _, let elapsed):
                Text("> \(total) item\(total == 1 ? "" : "s") · \(formatBytes(model.totalSize)) · \(String(format: "%.2fs", elapsed))")
            case .error(let msg):
                Text("! error: \(msg)").foregroundColor(.red)
            }
            if !model.selection.isEmpty {
                Text("· sel: \(model.selection.count) (\(formatBytes(model.selectedSize)))")
                    .foregroundColor(.yellow)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.green.opacity(0.85))
    }

    private func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        return "…" + s.suffix(max - 1)
    }
}

private struct BlinkingCursor: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let on = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Text("▮")
                .foregroundColor(.green)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - Themed picker (size threshold)

private struct TermPicker<T: Hashable & Identifiable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 6) {
                Text(label(selection))
                    .foregroundColor(.green)
                Text(open ? "▴" : "▾")
                    .foregroundColor(.green.opacity(0.7))
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(hover ? Color.green.opacity(0.15) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(options) { opt in
                    TermPickerRow(
                        label: label(opt),
                        selected: opt == selection
                    ) {
                        selection = opt
                        open = false
                    }
                }
            }
            .padding(4)
            .background(Color.black)
        }
    }
}

private struct TermPickerRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(selected ? "›" : " ")
                    .foregroundColor(.yellow)
                Text(label)
                    .foregroundColor(selected ? .yellow : .green)
                Spacer(minLength: 16)
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(minWidth: 110, alignment: .leading)
            .contentShape(Rectangle())
            .background(hover ? Color.green.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Reusable terminal button

private struct TermButton: View {
    let label: String
    var danger: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text("[ \(label) ]")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .foregroundColor(color)
                .background(hover && !disabled ? color.opacity(0.15) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color.opacity(disabled ? 0.3 : 0.7), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }

    private var color: Color {
        danger ? .red : .green
    }
}

// MARK: - File table

private struct FileTable: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6))

            Rectangle()
                .fill(Color.green.opacity(0.3))
                .frame(height: 1)

            tableArea
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onAppear { focused = true }
                .onKeyPress(.upArrow) { model.moveFocus(-1); return .handled }
                .onKeyPress(.downArrow) { model.moveFocus(1); return .handled }
                .onKeyPress(.pageUp) { model.moveFocus(-10); return .handled }
                .onKeyPress(.pageDown) { model.moveFocus(10); return .handled }
                .onKeyPress(.home) { model.focusFirst(); return .handled }
                .onKeyPress(.end) { model.focusLast(); return .handled }
                .onKeyPress(.return) { model.revealFocused(); return .handled }
                .onKeyPress(.space) { model.toggleFocused(); return .handled }
                .onKeyPress(keys: ["a"]) { _ in model.selectAll(); return .handled }
                .onKeyPress(keys: ["d"]) { _ in model.deselectAll(); return .handled }
                .onKeyPress(keys: ["i"]) { _ in model.ignoreSelected(); return .handled }
                .onKeyPress(keys: ["t"]) { _ in model.trashShortcut(); return .handled }
                .onKeyPress(keys: ["/"]) { _ in model.requestSearchFocus(); return .handled }
                .onKeyPress(keys: ["?"]) { _ in model.showShortcutsSheet = true; return .handled }
        }
        .background(Color.black.opacity(0.4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(focused ? Color.green.opacity(0.7) : Color.green.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var tableArea: some View {
        VStack(spacing: 0) {
            HStack {
                SelectAllToggle(model: model)
                    .frame(width: 36, alignment: .leading)
                Text("SIZE").frame(width: 90, alignment: .trailing)
                Text("MODIFIED").frame(width: 110, alignment: .leading)
                Text("PATH").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.green.opacity(0.6))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.green.opacity(0.08))

            if model.visibleFiles.isEmpty {
                EmptyState(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.visibleFiles.enumerated()), id: \.element.id) { idx, file in
                                FileRow(
                                    file: file,
                                    selected: model.selection.contains(file.id),
                                    focused: focused && model.focusedIndex == idx,
                                    onContextReveal: { model.reveal(file) },
                                    onContextTrashOne: {
                                        model.selection = [file.id]
                                        model.trashSelected()
                                    },
                                    onContextIgnore: { model.addToIgnoreList(file.path) }
                                )
                                .id(file.id)
                            }
                        }
                        .coordinateSpace(name: "rows")
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("rows"))
                                .onChanged { value in
                                    focused = true
                                    let startIdx = Int(value.startLocation.y / rowHeight)
                                    let currentIdx = Int(value.location.y / rowHeight)
                                    model.dragHitRange(start: startIdx, end: currentIdx)
                                }
                                .onEnded { _ in model.endDrag() }
                        )
                    }
                    .onChange(of: model.focusedIndex) { _, newIdx in
                        guard model.visibleFiles.indices.contains(newIdx) else { return }
                        proxy.scrollTo(model.visibleFiles[newIdx].id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct SearchBar: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("/")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(focused ? .yellow : .green.opacity(0.6))
            TextField("filter by path…   (press / to focus, esc to clear)", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.green)
                .focused($focused)
                .onSubmit { focused = false }
                .onKeyPress(.escape) {
                    if !model.searchQuery.isEmpty {
                        model.searchQuery = ""
                    }
                    focused = false
                    return .handled
                }
                .onChange(of: model.searchFocusToken) { _, _ in
                    focused = true
                }
            if !model.searchQuery.isEmpty {
                Button(action: { model.searchQuery = "" }) {
                    Text("[ x ]")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
            countLabel
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(model.searchQuery.isEmpty ? .green.opacity(0.5) : .yellow.opacity(0.85))
        }
    }

    @ViewBuilder
    private var countLabel: some View {
        if model.searchQuery.isEmpty {
            Text("\(model.files.count) item\(model.files.count == 1 ? "" : "s")")
        } else {
            Text("\(model.visibleFiles.count) / \(model.files.count)")
        }
    }
}

private struct SelectAllToggle: View {
    @ObservedObject var model: AppModel
    @State private var hover = false

    private enum Kind { case none, partial, all }

    private var kind: Kind {
        if model.visibleFiles.isEmpty || model.selection.isEmpty { return .none }
        if model.selection.count == model.visibleFiles.count { return .all }
        return .partial
    }

    private var glyph: String {
        switch kind {
        case .none: return "[ ]"
        case .partial: return "[~]"
        case .all: return "[x]"
        }
    }

    private var color: Color {
        switch kind {
        case .none: return .green.opacity(0.6)
        case .partial, .all: return .yellow
        }
    }

    var body: some View {
        Button(action: { model.toggleAll() }) {
            Text(glyph)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(hover ? Color.green.opacity(0.15) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.green.opacity(hover ? 0.6 : 0.0), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(model.visibleFiles.isEmpty)
        .onHover { hover = $0 }
        .help(kind == .all ? "Deselect all" : "Select all visible")
    }
}

private struct FileRow: View {
    let file: BigFile
    let selected: Bool
    let focused: Bool
    let onContextReveal: () -> Void
    let onContextTrashOne: () -> Void
    let onContextIgnore: () -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        HStack {
            Text(selected ? "[x]" : "[ ]")
                .frame(width: 36, alignment: .leading)
                .foregroundColor(selected ? .yellow : .green.opacity(0.6))
            Text(formatBytes(file.size))
                .frame(width: 90, alignment: .trailing)
                .foregroundColor(.green)
            Text(Self.dateFmt.string(from: file.modified))
                .frame(width: 110, alignment: .leading)
                .foregroundColor(.green.opacity(0.6))
            Text(file.path)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(selected ? .yellow : .green)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { onContextReveal() }
            Button("Move to Trash") { onContextTrashOne() }
            Divider()
            Button("Add to ignore list") { onContextIgnore() }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if focused {
            Color.green.opacity(0.18)
        } else if selected {
            Color.yellow.opacity(0.10)
        } else {
            Color.clear
        }
    }
}

private struct EmptyState: View {
    @ObservedObject var model: AppModel

    private var promptText: String {
        switch model.mode {
        case .devjunk: return "// press [ scan ] to inventory developer caches"
        default:       return "// pick a path and press [ scan ]"
        }
    }

    /// Modes whose scans walk ~/Library or /Library — paths macOS gates with TCC. If
    /// the user denied Full Disk Access (or never granted it), enumerator calls return
    /// nothing and the scan looks completed but empty. Hint them at the cause.
    private var needsFullDiskAccessHint: Bool {
        switch model.mode {
        case .devjunk: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            if !model.searchQuery.isEmpty && !model.files.isEmpty {
                Text("// no matches for /\(model.searchQuery)/")
                Text("// \(model.files.count) item\(model.files.count == 1 ? "" : "s") in scan, none match the filter")
            } else {
                switch model.state {
                case .scanning:
                    Text("// crawling filesystem…")
                    Text("// this can take a while on large trees")
                case .done(let total, _, _) where total == 0:
                    Text("// no matches")
                    switch model.mode {
                    case .dirs:
                        Text("// none of the watched names were found in this path")
                    case .files:
                        Text("// no files above \(model.threshold.label) — try a smaller size")
                    case .devjunk:
                        Text("// no dev caches present — nothing to clean")
                    }
                    if needsFullDiskAccessHint {
                        Text("// not seeing results you expected? this mode reads ~/Library and /Library — grant Full Disk Access in System Settings → Privacy & Security if scans look empty.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.yellow.opacity(0.6))
                            .padding(.top, 4)
                    }
                default:
                    Text(promptText)
                    switch model.mode {
                    case .dirs:
                        Text("// dirs mode finds folders by name. watching: \(model.dirNames.prefix(4).joined(separator: ", "))\(model.dirNames.count > 4 ? "…" : "")")
                            .multilineTextAlignment(.center)
                    case .files:
                        Text("// files mode finds individual large files")
                    case .devjunk:
                        Text("// Xcode DerivedData, simulator caches, npm/gradle/brew caches — safely regenerable")
                            .multilineTextAlignment(.center)
                    }
                }
            }
            Text("// press ? for keyboard shortcuts")
                .foregroundColor(.green.opacity(0.35))
                .padding(.top, 8)
        }
        .foregroundColor(.green.opacity(0.55))
        .font(.system(size: 12, design: .monospaced))
        .padding(40)
    }
}

// MARK: - Log

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green.opacity(0.7))
                            .id(idx)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color.black.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
            .onChange(of: lines.count) { _, n in
                proxy.scrollTo(n - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: - Sheets

private struct DirNamesSheet: View {
    @ObservedObject var model: AppModel
    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("// directory names")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()
                TermButton(label: "reset") { model.resetDirNames() }
                TermButton(label: "close") { model.showDirNamesSheet = false }
            }

            Text("in dirs mode, blob finds directories whose name matches one of these and ranks them by total recursive size. great for hunting node_modules, build outputs, caches.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.green.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("$").foregroundColor(.green.opacity(0.6))
                TextField("name (e.g. node_modules)", text: $newName)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.green.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.green.opacity(0.5), lineWidth: 1)
                    )
                    .onSubmit(add)
                TermButton(label: "add", disabled: trimmed.isEmpty) { add() }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.dirNames.isEmpty {
                        Text("// empty")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.green.opacity(0.5))
                            .padding(8)
                    } else {
                        ForEach(model.dirNames, id: \.self) { name in
                            HStack {
                                Text(name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.green)
                                Spacer()
                                TermButton(label: "x", danger: true) {
                                    model.removeDirName(name)
                                }
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            .background(Color.black.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(20)
        .frame(width: 600, height: 460)
        .background(Color.black)
        .foregroundColor(.green)
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespaces) }

    private func add() {
        model.addDirName(trimmed)
        newName = ""
    }
}

private struct IgnoreListSheet: View {
    @ObservedObject var model: AppModel
    @State private var newEntry: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("// ignore list")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()
                TermButton(label: "close") { model.showIgnoreSheet = false }
            }

            Text("paths added here are skipped on the next scan. directories ignore their whole subtree. add entries from the results table with right-click → ignore, or [ ignore ] in the action bar.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.green.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("$").foregroundColor(.green.opacity(0.6))
                TextField("/absolute/path/to/skip", text: $newEntry)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.green.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.green.opacity(0.5), lineWidth: 1)
                    )
                    .onSubmit(add)
                TermButton(label: "add", disabled: trimmed.isEmpty) { add() }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.ignoreList.isEmpty {
                        Text("// empty")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.green.opacity(0.5))
                            .padding(8)
                    } else {
                        ForEach(model.ignoreList, id: \.self) { entry in
                            HStack {
                                Text(entry)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.green)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                TermButton(label: "x", danger: true) {
                                    model.removeFromIgnoreList(entry)
                                }
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }
            .frame(minHeight: 200)
            .background(Color.black.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(20)
        .frame(width: 600, height: 420)
        .background(Color.black)
        .foregroundColor(.green)
    }

    private var trimmed: String { newEntry.trimmingCharacters(in: .whitespaces) }

    private func add() {
        let path = (trimmed as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        model.addToIgnoreList(path)
        newEntry = ""
    }
}

// MARK: - Shortcuts sheet

private struct ShortcutsSheet: View {
    @ObservedObject var model: AppModel

    private struct Group {
        let title: String
        let rows: [(keys: String, desc: String)]
    }

    private let groups: [Group] = [
        Group(title: "NAVIGATION", rows: [
            ("↑   ↓",        "move focus up / down"),
            ("PgUp  PgDn",   "move focus by 10"),
            ("Home  End",    "jump to first / last"),
            ("Return",       "reveal focused row in Finder"),
        ]),
        Group(title: "SELECTION", rows: [
            ("Space",        "toggle focused row"),
            ("a",            "select all visible"),
            ("d",            "deselect all"),
            ("Click",        "toggle a row"),
            ("Click + drag", "range-select"),
            ("Right-click",  "row actions menu"),
        ]),
        Group(title: "ACTIONS", rows: [
            ("i",            "add selected to ignore list"),
            ("t",            "move selected (or focused) to Trash"),
        ]),
        Group(title: "SEARCH", rows: [
            ("/",            "focus the search bar"),
            ("Esc",          "clear filter / leave search"),
        ]),
        Group(title: "APP", rows: [
            ("?",            "show this help"),
            ("⌘ W",          "close window"),
            ("⌘ Q",          "quit blob"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("// keyboard shortcuts")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()
                TermButton(label: "close") { model.showShortcutsSheet = false }
            }

            Text("table area must be focused for letter shortcuts. click anywhere on the rows or column header to focus it.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.green.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        ShortcutGroupView(title: group.title, rows: group.rows)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(20)
        .frame(width: 580, height: 560)
        .background(Color.black)
        .foregroundColor(.green)
    }
}

private struct ShortcutGroupView: View {
    let title: String
    let rows: [(keys: String, desc: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.green.opacity(0.55))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 14) {
                    Text(row.keys)
                        .frame(width: 130, alignment: .leading)
                        .foregroundColor(.yellow)
                    Text(row.desc)
                        .foregroundColor(.green.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }
}
