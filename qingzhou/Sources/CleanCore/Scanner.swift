import Foundation
import Darwin

public struct DirectoryScanStatus: Identifiable, Sendable {
    public enum Outcome: String, Sendable {
        case read = "已读取", missing = "目录不存在", denied = "权限不足", skipped = "跳过链接或非目录", failed = "读取失败"
    }
    public var id: String { url.path }
    public let url: URL
    public let outcome: Outcome
    public let detail: String
    public var incomplete: Bool { outcome == .denied || outcome == .failed }
}

private final class DirectoryScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: DirectoryScanStatus] = [:]
    func add(_ url: URL, _ outcome: DirectoryScanStatus.Outcome, _ detail: String) {
        let url = url.standardizedFileURL
        lock.lock(); defer { lock.unlock() }
        if records[url.path]?.incomplete == true { return }
        records[url.path] = DirectoryScanStatus(url: url, outcome: outcome, detail: detail)
    }
    var sorted: [DirectoryScanStatus] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { a, b in
            a.incomplete == b.incomplete ? a.id < b.id : a.incomplete
        }
    }
}


public struct ApplicationFileOwner: Sendable {
    let app: AppRecord
    let identifiers: Set<String>
    let declaredGroups: Set<String>
}

/// Read-only discovery. Matching is intentionally conservative; review candidates are never selected automatically.
public struct AppScanner: Sendable {
    public let home: URL
    public let applicationRoots: [URL]
    var readGroups: @Sendable (URL, String) -> Set<String> = {
        ApplicationGroupService.declaredIdentifiers(at: $0, expectedBundleID: $1)
    }
    private var scanLog: DirectoryScanLog?
    public func recordingDirectories<T>(_ scan: (Self) throws -> T) rethrows -> (result: T, directories: [DirectoryScanStatus]) {
        let log = DirectoryScanLog()
        var scanner = self
        scanner.scanLog = log
        let result = try scan(scanner)
        return (result, log.sorted)
    }

    private static let ownIdentifiers: Set<String> = ["cn.local.qingzhou", "com.qingzhou.cleaner", "local.qingzhou.cleaner", "org.qingzhou.cleaner"]
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applicationRoots: [URL]? = nil) {
        self.home = home.standardizedFileURL
        self.applicationRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications")]
    }

    public func scanApplications() -> ScanReport {
        var seen = Set<String>()
        var apps: [AppRecord] = []
        var warnings: [String] = []
        for root in applicationRoots {
            do { _ = try root.resourceValues(forKeys: [.isDirectoryKey]) }
            catch {
                if Self.directoryFailure(error) != .missing { warnings.append("无法检查应用目录 " + root.path + "，" + error.localizedDescription) }
                continue
            }
            if root.pathExtension.lowercased() == "app" {
                if let app = appRecord(at: root), seen.insert(app.id).inserted { apps.append(app) }
                continue
            }
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Self.keys,
                                                                 options: [.skipsHiddenFiles], errorHandler: { url, error in
                    warnings.append("未读到 " + url.path + "，" + error.localizedDescription)
                    return true
                }) else {
                warnings.append("无法读取应用目录：\(root.path)"); continue
            }
            for case let url as URL in iterator {
                guard let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { continue }
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    iterator.skipDescendants()
                    guard let app = appRecord(at: url), seen.insert(app.id).inserted else { continue }
                    apps.append(app)
                } else if iterator.level >= ApplicationInventoryTraversal.maximumApplicationLevel {
                    iterator.skipDescendants()
                }
            }
        }
        // Large bundles are measured when selected, rather than blocking the whole application list.
        warnings.append("应用列表仅统计主程序；关联文件需选中应用后读取。大型目录按限时遍历估算，受权限限制的目录可能遗漏。")
        return ScanReport(apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings)
    }

    public func relatedFiles(for app: AppRecord, measureSizes: Bool = true) -> [CleanFile] {
        relatedFiles(for: app, measureSizes: measureSizes, declaredGroups: readGroups(app.url, app.bundleID))
    }

    private func relatedFiles(for app: AppRecord, measureSizes: Bool, declaredGroups: Set<String>) -> [CleanFile] {
        guard !Task.isCancelled else { return [] }
        var files: [CleanFile] = []
        var seen = Set<String>()
        func append(_ url: URL, kind: FileKind, risk: FileRisk, selected: Bool, reason: String) {
            guard seen.insert(url.standardizedFileURL.path).inserted, isRealItem(url) else { return }
            let finalRisk: FileRisk = app.isProtected ? .protected : risk
            files.append(CleanFile(url: url, kind: kind, bytes: measureSizes ? Self.size(of: url) : 0, reason: reason,
                                   risk: finalRisk, defaultSelected: selected && !app.isProtected,
                                   ownerBundleID: app.bundleID.isEmpty ? nil : app.bundleID))
        }
        append(app.url, kind: .application, risk: app.isProtected ? .protected : .routine,
               selected: !app.isProtected, reason: app.isProtected ? "系统应用或清舟自身，禁止清理" : "应用程序本体")
        guard isUsableIdentifier(app.bundleID) else { return files }
        let bid = app.bundleID
        let associatedIDs = relatedIdentifiers(for: app)
        for location in libraryLocations {
            for entry in children(of: location.url) {
                guard !Task.isCancelled else { return [] }
                let name = entry.lastPathComponent
                let evidence = identifierEvidence(for: entry, kind: location.kind, identifiers: associatedIDs)
                let manual = evidence == nil && nameMatches(name, appName: app.name, kind: location.kind)
                guard evidence != nil || manual else { continue }
                let matchReason = evidence ?? "仅目录名称与应用相同，归属需人工核实"
                let risk: FileRisk = [.support, .container, .webData, .preference].contains(location.kind) ? .personal : .routine
                let selected = !manual && [.cache, .logs, .savedState].contains(location.kind)
                append(entry, kind: location.kind, risk: risk, selected: selected, reason: matchReason)
            }
        }
        for (relativePath, kind) in knownDirectories(for: bid) {
            guard !Task.isCancelled else { return [] }
            append(home.appendingPathComponent("Library").appendingPathComponent(relativePath), kind: kind,
                   risk: kind == .support ? .personal : .routine, selected: kind == .cache,
                   reason: "按应用完整标识核对的专属目录；个人资料目录需单独勾选")
        }
        for entry in children(of: home.appendingPathComponent("Library/Caches")) {
            guard !Task.isCancelled else { return [] }
            guard updaterCache(entry.lastPathComponent, identifier: bid) else { continue }
            append(entry, kind: .cache, risk: .routine, selected: false,
                   reason: "名称与此应用的常见更新缓存格式一致，需人工核实")
        }
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost")
        for entry in children(of: byHost) {
            guard !Task.isCancelled else { return [] }
            guard let owner = byHostIdentifier(entry.lastPathComponent), associatedIDs.contains(owner),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            append(entry, kind: .preference, risk: owner == bid ? .personal : .protected, selected: false,
                   reason: owner == bid ? "此设备的应用偏好设置，清理后设置会重置。" : "此设备上的内嵌辅助程序设置，仅供查看。")
        }
        for url in ApplicationGroupService.containerURLs(for: declaredGroups, home: home) {
            append(url, kind: .container, risk: .protected, selected: false,
                   reason: "应用或其扩展的签名声明使用此共享容器。其他成员也可能使用，可在访达查看。")
        }
        let scripts = home.appendingPathComponent("Library/Application Scripts")
        for entry in children(of: scripts) {
            let id = entry.lastPathComponent
            guard associatedIDs.contains(id), ApplicationScriptDirectory.accepts(id), isActualDirectory(entry) else { continue }
            let isMain = id == bid
            append(entry, kind: .support, risk: isMain ? .personal : .protected, selected: false,
                   reason: isMain ? "用户脚本目录与应用完整标识匹配，可能包含手写脚本，请逐项核对。" : "用户脚本目录与内嵌辅助程序标识匹配，仅供查看。")
        }
        for entry in children(of: home.appendingPathComponent("Library/Group Containers")) {
            guard !Task.isCancelled else { return [] }
            guard !declaredGroups.contains(entry.lastPathComponent), groupContainer(entry.lastPathComponent, identifier: bid),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            append(entry, kind: .container, risk: .personal, selected: false,
                   reason: "共享容器名称含完整应用标识，可能被同系列软件共用，需人工核实")
        }
        return files.sorted {
            if $0.kind == .application { return $1.kind != .application }
            if $1.kind == .application { return false }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    public func fileOwners(of apps: [AppRecord]) -> [String: ApplicationFileOwner] {
        var owners: [String: ApplicationFileOwner] = [:]
        for app in apps where !Task.isCancelled {
            owners[app.id] = ApplicationFileOwner(app: app, identifiers: relatedIdentifiers(for: app), declaredGroups: readGroups(app.url, app.bundleID))
        }
        return owners
    }

    /// Data may still be in use by a second copy or an unrelated application embedding the same helper.
    /// The inventory retains identities, while each review checks the file evidence currently on disk.
    public func reviewedFiles(for app: AppRecord, installed: [String: ApplicationFileOwner], originalURL: URL? = nil) -> [CleanFile] {
        let declared = installed[app.id]?.declaredGroups ?? readGroups(app.url, app.bundleID)
        let files = relatedFiles(for: app, measureSizes: true, declaredGroups: declared)
        let remaining = installed.values.filter { $0.app.url.standardizedFileURL.path != (originalURL ?? app.url).standardizedFileURL.path }
        guard !remaining.isEmpty else { return files }
        let hasCopy = !app.bundleID.isEmpty && remaining.contains { $0.app.bundleID == app.bundleID }
        let identifiers = remaining.reduce(into: Set<String>()) { $0.formUnion($1.identifiers) }
        let names = Set(remaining.map { $0.app.name })
        let bundleIDs = Set(remaining.map { $0.app.bundleID }.filter(isUsableIdentifier))
        let library = home.appendingPathComponent("Library")
        let known = bundleIDs.flatMap(knownDirectories).map { library.appendingPathComponent($0.0).standardizedFileURL.pathComponents }
        let locations = libraryLocations
        func hasOtherOwner(_ file: CleanFile) -> Bool {
            let path = file.url.standardizedFileURL.pathComponents
            if known.contains(where: { path.starts(with: $0) || $0.starts(with: path) }) { return true }
            let name = file.url.lastPathComponent
            let parent = file.url.deletingLastPathComponent().standardizedFileURL.path
            if parent == library.appendingPathComponent("Application Scripts").standardizedFileURL.path {
                return identifiers.contains(name)
            }
            if parent == library.appendingPathComponent("Group Containers").standardizedFileURL.path {
                return remaining.contains { $0.declaredGroups.contains(name) } || bundleIDs.contains { groupContainer(name, identifier: $0) }
            }
            if parent == library.appendingPathComponent("Preferences/ByHost").standardizedFileURL.path {
                return byHostIdentifier(name).map(identifiers.contains) ?? false
            }
            // A known nested directory can sit inside another app's matching name or identifier.
            for location in locations {
                let base = location.url.standardizedFileURL.pathComponents
                guard path.count > base.count, path.starts(with: base) else { continue }
                let childName = path[base.count]
                let child = location.url.appendingPathComponent(childName)
                if identifierEvidence(for: child, kind: location.kind, identifiers: identifiers) != nil { return true }
                if names.contains(where: { nameMatches(childName, appName: $0, kind: location.kind) }) { return true }
                return location.kind == .cache && bundleIDs.contains { updaterCache(childName, identifier: $0) }
            }
            return false
        }
        return files.map { file in
            guard file.kind != .application, hasCopy || hasOtherOwner(file) else { return file }
            return CleanFile(url: file.url, kind: file.kind, bytes: file.bytes,
                             reason: hasCopy ? "另一份同标识应用仍会使用关联数据，已保护。" : "此路径仍与其他已扫描应用或其辅助程序关联，已保护。",
                             risk: .protected, defaultSelected: false, ownerBundleID: file.ownerBundleID)
        }
    }

    public func leftovers(installed: [AppRecord]) -> [CleanFile] {
        var identifiers = Set(installed.map(\.bundleID).filter { !$0.isEmpty })
        identifiers.formUnion(Self.ownIdentifiers)
        if let ownID = Bundle.main.bundleIdentifier { identifiers.insert(ownID) }
        // Helper applications can use identifiers unrelated to the parent application.
        for app in installed { identifiers.formUnion(embeddedIdentifiers(in: app.url)) }
        let installedIDs = Set(identifiers.map { $0.lowercased() })
        var output: [CleanFile] = []
        func append(_ entry: URL, kind: FileKind, id: String, reason: String) {
            let personal = [.support, .container, .preference, .webData].contains(kind)
            output.append(CleanFile(url: entry, kind: kind, bytes: Self.size(of: entry), reason: reason,
                                    risk: personal ? .personal : .routine, defaultSelected: false, ownerBundleID: id))
        }
        func inferredCandidate(_ entry: URL, kind: FileKind, id: String?) {
            guard let id, isRealItem(entry), isReverseDNS(id) else { return }
            let normalized = id.lowercased()
            guard !isSystemIdentifier(normalized), !installedIDs.contains(where: {
                normalized == $0 || normalized.hasPrefix($0 + ".") || $0.hasPrefix(normalized + ".")
            }) else { return }
            append(entry, kind: kind, id: id,
                   reason: "未在已扫描应用及其辅助程序中找到标识 \(id)。可能属于未扫描位置的软件或后台组件，请核实后再选。")
        }
        for location in libraryLocations {
            for entry in children(of: location.url) {
                guard !Task.isCancelled else { return [] }
                guard isRealItem(entry) else { continue }
                let inferred: String?
                switch location.kind {
                case .launchAgent:
                    guard let label = orphanedUserAgent(at: entry, installedIDs: installedIDs) else { continue }
                    append(entry, kind: .launchAgent, id: label, reason: "启动配置指向已不存在的应用，配置归属需核对。若仍已加载，请先在“启动项目”中停用。")
                    continue
                case .container: inferred = containerIdentifier(entry) ?? identifier(from: entry.lastPathComponent, kind: location.kind)
                case .webData: inferred = webDataIdentifier(for: entry)
                default: inferred = identifier(from: entry.lastPathComponent, kind: location.kind)
                }
                inferredCandidate(entry, kind: location.kind, id: inferred)
            }
        }
        let library = home.appendingPathComponent("Library")
        for entry in children(of: library.appendingPathComponent("Application Scripts")) {
            guard !Task.isCancelled else { return [] }
            let id = entry.lastPathComponent
            if ApplicationScriptDirectory.accepts(id), isActualDirectory(entry) {
                inferredCandidate(entry, kind: .support, id: id)
            }
        }
        for entry in children(of: library.appendingPathComponent("Preferences/ByHost")) {
            guard !Task.isCancelled else { return [] }
            if (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                inferredCandidate(entry, kind: .preference, id: byHostIdentifier(entry.lastPathComponent))
            }
        }
        let remainingNames = Set(installed.map { $0.name.lowercased() })
        for (id, relative) in ApplicationSupportDirectory.vendorSubpaths where !installedIDs.contains(id.lowercased()) {
            guard !Task.isCancelled else { return [] }
            let parts = relative.split(separator: "/").map { $0.lowercased() }
            guard remainingNames.isDisjoint(with: parts) else { continue }
            for (path, kind) in knownDirectories(for: id) {
                let entry = library.appendingPathComponent(path)
                guard isActualDirectory(entry) else { continue }
                append(entry, kind: kind, id: id,
                       reason: "此路径是应用 \(id) 的已知专属目录。扫描范围内未发现该应用，可能仍被自定义配置使用，请核对。")
            }
        }
        return output.sorted {
            $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes
        }
    }

    public func caches() -> [CleanFile] {
        children(of: home.appendingPathComponent("Library/Caches")).filter { isRealItem($0) }.map { entry in
            let identifier = entry.lastPathComponent
            let vendorDirectory = ["google", "bravesoftware", "microsoft", "adobe", "mozilla", "jetbrains"].contains(identifier.lowercased())
            let protected = isSystemIdentifier(identifier) || Self.ownIdentifiers.contains(identifier) || identifier == "Qingzhou" || vendorDirectory
            return CleanFile(url: entry, kind: .cache, bytes: Self.size(of: entry),
                             reason: vendorDirectory ? "厂商共享缓存目录；请进入应用管理，按具体应用清理其中的专属子目录" : (protected ? "系统或清舟缓存，保留以避免干扰正在运行的服务" : "用户缓存；可能含离线内容，请先退出对应应用。目录名称不能单独证明归属。"),
                             risk: protected ? .protected : .routine, defaultSelected: false,
                             ownerBundleID: isReverseDNS(identifier) ? identifier : nil)
        }.sorted { $0.bytes > $1.bytes }
    }

    public func extensions() -> [CleanFile] {
        // Only package types appropriate to each extension directory are candidates.
        // In particular, Dictionaries also contains system learning databases, not removable extensions.
        let folders: [(String, Set<String>)] = [
            ("Internet Plug-Ins", ["plugin", "webplugin", "bundle"]),
            ("PreferencePanes", ["prefpane"]), ("QuickLook", ["qlgenerator"]),
            ("Screen Savers", ["saver"]), ("Services", ["workflow", "service", "app"]),
            ("Widgets", ["wdgt"]), ("Audio/Plug-Ins/Components", ["component"]),
            ("Audio/Plug-Ins/VST", ["vst"]), ("Audio/Plug-Ins/VST3", ["vst3"]),
            ("Dictionaries", ["dictionary"]), ("ColorPickers", ["colorpicker", "bundle"]),
            ("Input Methods", ["app", "bundle", "inputmethod"])
        ]
        var output: [CleanFile] = []
        for library in [home.appendingPathComponent("Library"), URL(fileURLWithPath: "/Library")] {
            for (folder, suffixes) in folders {
                for entry in children(of: library.appendingPathComponent(folder)) {
                    guard suffixes.contains(entry.pathExtension.lowercased()), isRealItem(entry),
                          (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    let systemWide = library.path == "/Library"
                    let identifier = bundleDictionary(at: entry)?["CFBundleIdentifier"] as? String
                    let appleComponent = isSystemIdentifier(identifier ?? "") || isSystemIdentifier(entry.lastPathComponent)
                    let ownComponent = Self.ownIdentifiers.contains(identifier ?? "")
                    let protected = systemWide || appleComponent || ownComponent
                    let reason: String
                    if appleComponent || ownComponent {
                        reason = "系统或清舟组件，禁止清理"
                    } else if systemWide {
                        reason = "\(folder) 中的全机组件；仅供查看，请使用其官方卸载方式"
                    } else {
                        reason = "\(folder) 中的用户扩展包；移除前请退出使用它的软件"
                    }
                    output.append(CleanFile(url: entry, kind: .extensionFile, bytes: Self.size(of: entry),
                                            reason: reason, risk: protected ? .protected : .personal,
                                            defaultSelected: false, ownerBundleID: identifier))
                }
            }
        }
        return output.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    /// Returns the bytes observed within bounded enumeration; never follows symbolic links.
    public static func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        let deadline = Date().addingTimeInterval(0.35)
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                             options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let item as URL in iterator {
            count += 1
            if count > 30_000 || (count % 128 == 0 && Date() > deadline) { break }
            guard let itemValues = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if itemValues.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if itemValues.isRegularFile == true { total += Int64(itemValues.fileSize ?? 0) }
        }
        return total
    }

    private var libraryLocations: [(url: URL, kind: FileKind)] {
        let locations: [(String, FileKind)] = [("Caches", .cache), ("Preferences", .preference), ("Application Support", .support),
         ("Containers", .container), ("Logs", .logs), ("Saved Application State", .savedState),
         ("WebKit", .webData), ("HTTPStorages", .webData), ("Cookies", .webData), ("LaunchAgents", .launchAgent)]
        return locations.map { (home.appendingPathComponent("Library").appendingPathComponent($0.0), $0.1) }
    }

    private func knownDirectories(for identifier: String) -> [(String, FileKind)] {
        let directory: String
        switch identifier {
        case "com.microsoft.edgemac": directory = "Microsoft Edge"
        case "org.mozilla.firefox": directory = "Firefox"
        case "com.microsoft.VSCode": directory = "Code"
        case "md.obsidian": directory = "obsidian"
        default:
            guard let vendorDirectory = ApplicationSupportDirectory.vendorSubpaths[identifier] else { return [] }
            directory = vendorDirectory
        }
        return [("Application Support/" + directory, .support), ("Caches/" + directory, .cache)]
    }

    private func appRecord(at url: URL) -> AppRecord? {
        guard isRealItem(url), let info = bundleDictionary(at: url) else { return nil }
        let bid = info["CFBundleIdentifier"] as? String ?? ""
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        let version = ApplicationMetadata.version(in: info)
        let protected = url.path.hasPrefix("/System/") || isSystemIdentifier(bid) || Self.ownIdentifiers.contains(bid) ||
            (!bid.isEmpty && bid == Bundle.main.bundleIdentifier) || url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        return AppRecord(url: url, name: name, bundleID: bid, version: version,
                         bytes: Self.size(of: url), isProtected: protected,
                         feedURL: ApplicationMetadata.declaredFeed(in: info),
                         hasStoreReceipt: ApplicationMetadata.hasNativeStoreReceipt(at: url))
    }

    private func isRealItem(_ url: URL) -> Bool {
        do {
            let value = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            return value.isSymbolicLink != true && url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
        } catch {
            recordReadError(error, at: url)
            return false
        }
    }

    private func recordReadError(_ error: Error, at url: URL) {
        let outcome = Self.directoryFailure(error)
        if outcome == .denied || outcome == .failed { scanLog?.add(url, outcome, error.localizedDescription) }
    }

    private func isActualDirectory(_ url: URL) -> Bool {
        isRealItem(url) && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func children(of url: URL) -> [URL] {
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                scanLog?.add(url, .skipped, "保留此路径")
                return []
            }
            let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys,
                                                                     options: [.skipsHiddenFiles])
            scanLog?.add(url, .read, "已列举 " + String(entries.count) + " 个可见子项")
            return entries
        } catch {
            scanLog?.add(url, Self.directoryFailure(error), error.localizedDescription)
            return []
        }
    }

    static func directoryFailure(_ error: Error) -> DirectoryScanStatus.Outcome {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileReadNoPermissionError { return .denied }
            if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { return .missing }
        }
        if ns.domain == NSPOSIXErrorDomain {
            if [Int(EPERM), Int(EACCES)].contains(ns.code) { return .denied }
            if ns.code == Int(ENOENT) { return .missing }
        }
        if let cause = ns.userInfo[NSUnderlyingErrorKey] as? NSError, cause !== ns { return directoryFailure(cause) }
        return .failed
    }

    private func orphanedUserAgent(at url: URL, installedIDs: Set<String>) -> String? {
        guard url.pathExtension == "plist", let config = dictionary(at: url), let label = config["Label"] as? String,
              url.deletingPathExtension().lastPathComponent == label, isReverseDNS(label),
              !isSystemIdentifier(label.lowercased()) else { return nil }
        var owners = (config["AssociatedBundleIdentifiers"] as? [String]) ?? []
        if let id = config["AssociatedBundleIdentifiers"] as? String { owners.append(id) }
        owners.append(label)
        guard !owners.contains(where: { candidate in
            let id = candidate.lowercased()
            return isSystemIdentifier(id) || installedIDs.contains { $0 == id || $0.hasPrefix(id + ".") || id.hasPrefix($0 + ".") }
        }), let program = (config["Program"] as? String) ?? (config["ProgramArguments"] as? [String])?.first,
           program.hasPrefix("/"), !program.split(separator: "/").contains("..") else { return nil }
        var app = URL(fileURLWithPath: program)
        while app.path != "/", app.pathExtension.lowercased() != "app" { app.deleteLastPathComponent() }
        let path = app.standardizedFileURL
        guard path.pathExtension.lowercased() == "app",
              path.path == path.resolvingSymlinksInPath().standardizedFileURL.path,
              applicationRoots.contains(where: { path.pathComponents.starts(with: $0.standardizedFileURL.pathComponents) }) else { return nil }
        var statInfo = stat()
        return lstat(path.path, &statInfo) == -1 && errno == ENOENT ? label : nil
    }

    private func dictionary(at url: URL) -> [String: Any]? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_000_000 else { return nil }
            let data = try Data(contentsOf: url)
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        } catch { recordReadError(error, at: url); return nil }
    }

    private func bundleDictionary(at url: URL) -> [String: Any]? {
        ApplicationMetadata.information(at: url)
    }

    private func containerIdentifier(_ url: URL) -> String? {
        dictionary(at: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))?["MCMMetadataIdentifier"] as? String
    }

    private func nameMatches(_ name: String, appName: String, kind: FileKind) -> Bool {
        [.cache, .logs, .support].contains(kind) && appName.count >= 3 && name.caseInsensitiveCompare(appName) == .orderedSame
    }

    private func updaterCache(_ name: String, identifier: String) -> Bool {
        [".ShipIt", ".sparkle", ".Squirrel"].contains { name == identifier + $0 }
    }

    private func groupContainer(_ name: String, identifier: String) -> Bool {
        let suffix = "." + identifier
        return name == "group." + identifier || (name.hasSuffix(suffix) && name.dropLast(suffix.count).count == 10)
    }

    private func identifierEvidence(for entry: URL, kind: FileKind, identifiers: Set<String>) -> String? {
        if kind == .webData {
            // An exact filename can also be an app's legacy single-file web store.
            let id = webDataIdentifier(for: entry) ?? entry.lastPathComponent
            guard identifiers.contains(id) else { return nil }
            return "网页数据目录或凭据文件与应用或内嵌辅助程序完整标识匹配：\(id)"
        }
        if let matched = identifiers.first(where: { matches(name: entry.lastPathComponent, identifier: $0, kind: kind) }) {
            return "文件名与应用或其内嵌辅助程序完整标识匹配：\(matched)"
        }
        if kind == .container, let id = containerIdentifier(entry), identifiers.contains(id) {
            return "容器元数据与应用或内嵌辅助程序完整标识匹配：\(id)"
        }
        if kind == .launchAgent, let label = dictionary(at: entry)?["Label"] as? String, identifiers.contains(label) {
            return "启动配置标识与应用匹配；删除前应先停用启动项"
        }
        return nil
    }

    private func matches(name: String, identifier: String, kind: FileKind) -> Bool {
        switch kind {
        case .preference, .launchAgent: return name == identifier + ".plist"
        case .savedState: return name == identifier + ".savedState"
        default: return name == identifier
        }
    }

    private func webDataIdentifier(for entry: URL) -> String? {
        guard isRealItem(entry), let type = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return nil }
        let name = entry.lastPathComponent
        if type.isRegularFile == true,
           let suffix = [".binarycookies.lock", ".binarycookies"].first(where: { name.hasSuffix($0) }) {
            return String(name.dropLast(suffix.count))
        }
        return type.isDirectory == true ? name : nil
    }

    private func byHostIdentifier(_ name: String) -> String? {
        guard name.hasSuffix(".plist") else { return nil }
        let domainAndDevice = name.dropLast(".plist".count)
        guard let dot = domainAndDevice.lastIndex(of: "."),
              UUID(uuidString: String(domainAndDevice[domainAndDevice.index(after: dot)...])) != nil else { return nil }
        return String(domainAndDevice[..<dot])
    }


    private func identifier(from filename: String, kind: FileKind) -> String? {
        switch kind {
        case .preference: return filename.hasSuffix(".plist") ? String(filename.dropLast(6)) : nil
        case .savedState: return filename.hasSuffix(".savedState") ? String(filename.dropLast(11)) : nil
        default: return filename
        }
    }

    private func isUsableIdentifier(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("\\") && value != "." && value != ".."
    }

    private func isReverseDNS(_ value: String) -> Bool {
        guard isUsableIdentifier(value), value.count < 256 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }
    }

    private func isSystemIdentifier(_ identifier: String) -> Bool {
        identifier == "com.apple" || identifier.hasPrefix("com.apple.") || identifier.hasPrefix("group.com.apple.")
    }

    public func relatedIdentifiers(for app: AppRecord) -> Set<String> {
        Set([app.bundleID]).union(embeddedIdentifiers(in: app.url)).filter {
            isUsableIdentifier($0) && ($0 == app.bundleID || !isSystemIdentifier($0))
        }
    }

    private func embeddedIdentifiers(in application: URL) -> Set<String> {
        var identifiers = Set<String>()
        var roots = ["Contents/Library", "Contents/Frameworks", "Contents/PlugIns", "Contents/XPCServices", "Contents/Helpers"].map(application.appendingPathComponent)
        if let wrapped = ApplicationMetadata.wrappedBundle(in: application) {
            roots += ["PlugIns", "Extensions", "Frameworks", "Watch"].map(wrapped.appendingPathComponent)
        }
        for root in roots {
            if Task.isCancelled { return [] }
            guard isRealItem(root), let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                                 options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            let deadline = Date().addingTimeInterval(0.15)
            var count = 0
            for case let url as URL in iterator {
                if Task.isCancelled { return [] }
                count += 1
                if count > 10_000 || (count % 64 == 0 && Date() > deadline) { break }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants(); continue }
                if ["app", "xpc", "appex", "bundle", "framework"].contains(url.pathExtension.lowercased()),
                   let identifier = bundleDictionary(at: url)?["CFBundleIdentifier"] as? String {
                    identifiers.insert(identifier)
                }
                if ["node_modules", "Resources", "_CodeSignature", "Headers"].contains(url.lastPathComponent) { iterator.skipDescendants() }
            }
        }
        return identifiers
    }
}
