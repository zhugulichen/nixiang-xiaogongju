import Foundation
import AppKit
import Carbon

public enum TrashMoveMethod: Sendable {
    case direct, systemInteractive, systemWithFinderFallback, finderInteractive
}

// Paths travel as event parameters, never as executable script source.
enum FinderRecycleBridge {
    static let source = """
    on recyclePath(inputPath)
        with timeout of 86400 seconds
            tell application id "com.apple.finder"
                set recycledItem to delete (POSIX file inputPath as alias)
                return URL of recycledItem
            end tell
        end timeout
    end recyclePath
    """

    static func event(path: String) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "recyclePath"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: path), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    static func destination(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw CleanError.refused("访达未返回有效的本机废纸篓位置，请检查文件位置。")
        }
        return url.standardizedFileURL
    }

    static func recycle(_ url: URL) throws -> URL {
        guard !Thread.isMainThread else { throw CleanError.refused("访达回收操作须在后台执行。") }
        guard let script = NSAppleScript(source: source) else { throw CleanError.refused("无法建立访达回收请求。") }
        var details: NSDictionary?
        let reply = script.executeAppleEvent(event(path: url.path), error: &details)
        if let details {
            let code = (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            let message = details[NSAppleScript.errorMessage] as? String ?? "访达回收未完成，请核对文件位置。"
            throw NSError(domain: NSOSStatusErrorDomain, code: code,
                          userInfo: [NSLocalizedDescriptionKey: String(message.prefix(2_000))])
        }
        guard let value = reply.stringValue else { throw CleanError.refused("访达未确认恢复位置，请检查原位置和废纸篓。") }
        return try destination(value)
    }
}

public struct TrashFailure: LocalizedError, Codable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case validation, move, restore, skipped
    }
    public enum Category: String, Codable, Sendable {
        case applicationManagement, appData, fileAccess, automation, cancelled, other
    }

    public let stage: Stage
    public let category: Category
    public let path: String
    public let systemCodes: [String]
    public let message: String

    public var errorDescription: String? {
        ([message, path] + (systemCodes.isEmpty ? [] : [systemCodes.joined(separator: " → ")])).joined(separator: "\n")
    }

    fileprivate static func describe(_ error: Error, at url: URL, stage: Stage, home: URL) -> Self {
        if let failure = error as? TrashFailure { return failure }
        let chain = errorChain(error as NSError)
        let cancelled = chain.contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSUserCancelledError)
                || ($0.domain == NSOSStatusErrorDomain && [-128, -60006].contains($0.code))
                || ($0.domain == NSPOSIXErrorDomain && $0.code == ECANCELED)
        }
        let denied = chain.contains {
            ($0.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains($0.code))
                || ($0.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains($0.code))
                || ($0.domain == NSOSStatusErrorDomain && [-54, -5000, -60005].contains($0.code))
        }
        let category: Category
        let message: String
        if cancelled {
            category = .cancelled; message = "已取消系统文件操作。"
        } else if chain.contains(where: { $0.domain == NSOSStatusErrorDomain && $0.code == -1743 }) {
            category = .automation
            message = "系统尚未允许清舟控制访达。可在“隐私与安全 → 自动化 → 清舟”中允许访达，再重新检查应用；也可在访达手动移到废纸篓。"
        } else if denied {
            let parent = url.standardizedFileURL.deletingLastPathComponent().path
            let containerParents = ["Library/Containers", "Library/Group Containers"].map { home.appendingPathComponent($0).path }
            if url.pathExtension.lowercased() == "app" {
                category = .applicationManagement
                message = "系统拒绝普通回收。应用管理授权或文件权限均可能影响操作；若授权已开启，可选择“通过访达回收”，由系统处理必要的确认。"
            } else if containerParents.contains(parent) {
                category = .appData
                message = "系统拒绝操作其他应用的数据。请在系统询问时核对并允许清舟访问，或先保留这个容器。"
            } else {
                category = .fileAccess
                message = "系统拒绝操作此文件。请检查原位置、废纸篓的访问权限，以及文件是否已锁定。"
            }
        } else {
            category = .other
            message = String(error.localizedDescription.prefix(2_000))
        }
        return Self(stage: stage, category: category, path: url.path,
                    systemCodes: chain.map { "\($0.domain.prefix(100)) \($0.code)" }, message: message)
    }

    private static func errorChain(_ original: NSError) -> [NSError] {
        var queue = [original], found: [NSError] = [], seen = Set<ObjectIdentifier>()
        while !queue.isEmpty && found.count < 12 {
            let current = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
            found.append(current)
            if let error = current.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(error) }
            for key in [NSMultipleUnderlyingErrorsKey, "NSDetailedErrors"] {
                if let errors = current.userInfo[key] as? [NSError] { queue.append(contentsOf: errors.prefix(12)) }
            }
        }
        return found
    }
}

fileprivate struct TrashItemIdentity: Codable, Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int?
    let birthNanoseconds: Int?

    func matches(_ current: Self) -> Bool {
        device == current.device && inode == current.inode &&
            (birthSeconds == nil || (birthSeconds == current.birthSeconds && birthNanoseconds == current.birthNanoseconds))
    }

    static func read(_ url: URL) throws -> Self {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Self(device: status.st_dev, inode: status.st_ino,
                    birthSeconds: status.st_birthtimespec.tv_sec, birthNanoseconds: status.st_birthtimespec.tv_nsec)
    }
}

public struct TrashSelectionSnapshot: Sendable {
    fileprivate let identities: [String: TrashItemIdentity]

    fileprivate func require(_ current: TrashItemIdentity, at url: URL) throws {
        guard identities[url.standardizedFileURL.path] == current else {
            throw CleanError.refused("确认清单中的文件身份已改变，请重新检查。")
        }
    }
}

public struct TrashEntry: Identifiable, Codable, Sendable {
    public var id: String { originalURL.path }
    public let originalURL: URL
    public var trashURL: URL?
    public var error: String?
    public var restored: Bool
    public var ownerBundleID: String? = nil
    public var failure: TrashFailure? = nil
    fileprivate var kind: FileKind?
    public fileprivate(set) var recycledByFinder: Bool? = nil
    fileprivate var itemIdentity: TrashItemIdentity? = nil

    init(originalURL: URL, trashURL: URL?, error: String?, restored: Bool, ownerBundleID: String? = nil) {
        self.originalURL = originalURL; self.trashURL = trashURL; self.error = error; self.restored = restored; self.ownerBundleID = ownerBundleID
    }
}

public struct TrashBatch: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public var entries: [TrashEntry]
    public var successCount: Int { entries.filter { $0.trashURL != nil && $0.error == nil }.count }
}

public enum CleanError: LocalizedError {
    case refused(String)
    public var errorDescription: String? { if case .refused(let message) = self { return message }; return nil }
}

/// Only explicit, reviewable items may enter the system Trash. No permanent delete operation exists.
public final class TrashService: @unchecked Sendable {
    private let home: URL
    private let appRoots: [URL]
    private let historyURL: URL
    private let testTrash: URL?
    private let fm = FileManager.default
    private let protection: ApplicationProtectionPolicy
    private let lock = NSRecursiveLock()

    // Internal injection points keep tests isolated from real applications and disk permissions.
    struct RunningApplication {
        var bundleID: String?
        var url: URL?
        var name: String
    }
    var runningApplications: () -> [RunningApplication] = {
        NSWorkspace.shared.runningApplications.map {
            RunningApplication(bundleID: $0.bundleIdentifier, url: $0.bundleURL, name: $0.localizedName ?? "应用")
        }
    }
    struct RecycleReply {
        let destinations: [URL: URL]
        let error: Error?
    }
    private final class RecycleReplyBox: @unchecked Sendable {
        var reply: RecycleReply?
    }

    // Submit from a separate dispatch block so the caller never waits on the callback's own queue.
    // Do not time out a pending system prompt: the filesystem operation could still complete later.
    var systemRecycle: (URL) throws -> RecycleReply = { url in
        guard !Thread.isMainThread else { throw CleanError.refused("系统回收操作须在后台执行。") }
        let done = DispatchSemaphore(value: 0), box = RecycleReplyBox()
        DispatchQueue.global(qos: .userInitiated).async {
            NSWorkspace.shared.recycle([url]) { moved, error in
                box.reply = RecycleReply(destinations: moved, error: error)
                done.signal()
            }
        }
        done.wait()
        guard let reply = box.reply else { throw CleanError.refused("系统未返回回收结果，请核对文件位置。") }
        return reply
    }
    // Run the retry in this process so any access granted to the app applies directly.
    var directRecycle: (URL) throws -> URL? = { url in
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
    var finderRecycle: (URL) throws -> URL = FinderRecycleBridge.recycle
    var beforeJournalWrite: (() throws -> Void)?
    var launchAgentLoaded: (String) -> Bool? = { label in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { process.terminate(); return nil }
        if process.terminationStatus == 0 { return true }
        // launchctl returns ESRCH (113) when the named service is not loaded.
        return process.terminationStatus == 113 ? false : nil
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationRoots: [URL]? = nil, historyURL: URL? = nil, testTrashDirectory: URL? = nil,
                protection: ApplicationProtectionPolicy = ApplicationProtectionPolicy()) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.appRoots = (applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.historyURL = (historyURL ?? home.appendingPathComponent("Library/Application Support/Qingzhou/history.json")).standardizedFileURL
        self.testTrash = testTrashDirectory?.standardizedFileURL
        self.protection = protection
    }

    public func history() -> [TrashBatch] {
        lock.lock(); defer { lock.unlock() }
        return (try? readHistory()) ?? []
    }

    private func readHistory() throws -> [TrashBatch] {
        try rejectSymlinkPath(historyURL)
        guard exists(historyURL) else { return [] }
        return try JSONDecoder().decode([TrashBatch].self, from: Data(contentsOf: historyURL))
    }

    private func save(_ batches: [TrashBatch]) throws {
        try rejectSymlinkPath(historyURL)
        try fm.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(batches)
        try beforeJournalWrite?()
        try rejectSymlinkPath(historyURL)
        try data.write(to: historyURL, options: .atomic)
    }

    private func inside(_ path: URL, root: URL) -> Bool {
        let child = path.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return child.count > parent.count && child.starts(with: parent)
    }

    private func overlaps(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL == second.standardizedFileURL || inside(first, root: second) || inside(second, root: first)
    }

    // fileExists follows symlinks and misses dangling links; attributesOfItem does neither.
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }

    private func rejectSymlinkPath(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw CleanError.refused("只允许本机文件路径。") }
        let path = url.standardizedFileURL
        guard path.path == path.resolvingSymlinksInPath().path else {
            throw CleanError.refused("拒绝处理符号链接路径：\(url.path)")
        }
        var component = path
        while component.path != "/" {
            if let attributes = try? fm.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // Foundation canonicalizes macOS's system-owned /private aliases back to
                // /var and /tmp. Permit only these exact OS aliases, never user-created links.
                let systemAliases = ["/var": "private/var", "/tmp": "private/tmp"]
                let destination = try? fm.destinationOfSymbolicLink(atPath: component.path)
                guard let expected = systemAliases[component.path], destination == expected || destination == "/" + expected else {
                    throw CleanError.refused("拒绝处理符号链接路径：\(url.path)")
                }
            }
            component.deleteLastPathComponent()
        }
    }

    private func protectedName(_ name: String) -> Bool {
        let name = name.lowercased()
        let exact: Set<String> = ["qingzhou", "cn.local.qingzhou", "apple", "addressbook", "clouddocs", "cloudkit", "callhistorydb", "dock", "knowledge", "mobilesync", "syncservices", "safari", "mail", "loginwindow.plist", "pbs.plist", "nsglobaldomain"]
        return name.hasPrefix(".") || name.hasPrefix("com.apple.") || name == "com.apple" || name.contains(".com.apple.") || name.hasPrefix("cn.local.qingzhou.") || exact.contains(name)
    }

    /// Used for both removal and restoration. A journal is data, never authority to move arbitrary paths.
    private func validateDestination(_ url: URL, ownerBundleID: String? = nil, payload: URL? = nil, kind: FileKind? = nil) throws -> Bool {
        let path = url.standardizedFileURL
        try rejectSymlinkPath(path)
        guard !inside(path, root: URL(fileURLWithPath: "/System")), path.path != "/System" else {
            throw CleanError.refused("系统组件不能清理或覆盖。")
        }
        guard !overlaps(path, Bundle.main.bundleURL), !overlaps(path, historyURL),
              !overlaps(path, home.appendingPathComponent(".Trash")),
              !(testTrash.map { overlaps(path, $0) } ?? false) else {
            throw CleanError.refused("清舟自身、运行记录和废纸篓受到保护。")
        }
        guard !protectedName(path.lastPathComponent) else {
            throw CleanError.refused("系统组件或清舟自身的数据受到保护。")
        }
        if kind == .installer {
            let installers = InstallerFiles(home: home)
            guard installers.matchesFormat(at: payload ?? path, for: path) else {
                throw CleanError.refused("只能处理下载目录中已核对格式的安装文件。")
            }
            if payload == nil, !installers.canMoveImage(at: path) {
                throw CleanError.refused("映像已挂载或无法核对挂载状态，请先弹出后再检查。")
            }
            return false
        }
        let library = home.appendingPathComponent("Library")
        guard path.path != library.appendingPathComponent("Preferences/ByHost").path else {
            throw CleanError.refused("主机偏好设置目录不能整体清理，请选择具体应用的文件。")
        }
        let userRoots = ["Caches", "Logs", "Preferences", "Application Support", "Containers", "Group Containers", "Saved Application State", "WebKit", "HTTPStorages", "Cookies", "LaunchAgents", "Internet Plug-Ins", "PreferencePanes", "Screen Savers", "QuickLook", "Services", "Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Widgets", "Dictionaries", "ColorPickers", "Input Methods"].map { library.appendingPathComponent($0) }
        let appAllowed = path.pathExtension.lowercased() == "app" && appRoots.contains { inside(path, root: $0) }
        let dataAllowed = userRoots.contains { path.deletingLastPathComponent().path == $0.path }
        let vendorNames: Set<String> = ["google", "bravesoftware", "microsoft", "adobe", "mozilla", "jetbrains"]
        let vendorParent = [library.appendingPathComponent("Caches"), library.appendingPathComponent("Application Support")].contains { path.deletingLastPathComponent() == $0 }
        guard !(vendorParent && vendorNames.contains(path.lastPathComponent.lowercased())) else {
            throw CleanError.refused("厂商共享目录不能整体清理，请选择具体应用的数据。")
        }
        let scriptsDirectory = path.deletingLastPathComponent().path == library.appendingPathComponent("Application Scripts").path
        if scriptsDirectory {
            guard ownerBundleID == path.lastPathComponent, ApplicationScriptDirectory.accepts(path.lastPathComponent) else {
                throw CleanError.refused("脚本目录必须与应用完整标识一致。共享组及辅助程序脚本仅供查看。")
            }
            let item = payload ?? path
            let attributes = try fm.attributesOfItem(atPath: item.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CleanError.refused("脚本项目必须是实际目录。") }
        }
        let nestedAllowed = ownerBundleID.flatMap { ApplicationSupportDirectory.vendorSubpaths[$0] }.map { relative in
            ["Application Support", "Caches"].contains { path.path == library.appendingPathComponent($0).appendingPathComponent(relative).path }
        } ?? false
        let byHostAllowed: Bool
        if path.deletingLastPathComponent().path == library.appendingPathComponent("Preferences/ByHost").path, let ownerBundleID, !ownerBundleID.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: ownerBundleID)
            byHostAllowed = path.lastPathComponent.range(of: "^" + escaped + "\\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\.plist$", options: .regularExpression) != nil
        } else { byHostAllowed = false }
        guard appAllowed || dataAllowed || scriptsDirectory || nestedAllowed || byHostAllowed else { throw CleanError.refused("该路径不在可清理或恢复范围内：\(path.path)") }
        // A custom applications root may contain an app, but never grants access inside that app.
        if appAllowed {
            var parent = path.deletingLastPathComponent()
            while parent.path != "/" {
                guard parent.pathExtension.lowercased() != "app" else { throw CleanError.refused("不能单独移动应用内部的组件。") }
                parent.deleteLastPathComponent()
            }
        }
        return appAllowed
    }

    private func validatedBundleID(at url: URL) throws -> String {
        guard let identifier = ApplicationMetadata.information(at: url)?["CFBundleIdentifier"] as? String,
              !identifier.isEmpty, !identifier.hasPrefix("com.apple."), identifier != "cn.local.qingzhou" else {
            throw CleanError.refused("应用身份无法确认，或属于受保护应用。")
        }
        return identifier
    }

    private func checkRunning(path: URL, ownerBundleID: String?) throws {
        for app in runningApplications() {
            let sameID = ownerBundleID != nil && app.bundleID == ownerBundleID
            let inferredID = app.bundleID.map { path.lastPathComponent == $0 || path.lastPathComponent.hasPrefix($0 + ".") } ?? false
            let sameName = path.lastPathComponent.caseInsensitiveCompare(app.name) == .orderedSame || app.url.map { path.lastPathComponent.caseInsensitiveCompare($0.deletingPathExtension().lastPathComponent) == .orderedSame } == true
            let relatedPath = app.url.map { overlaps(path, $0.resolvingSymlinksInPath()) } ?? false
            if sameID || inferredID || sameName || relatedPath {
                throw CleanError.refused("请先退出“\(app.name)”，再处理关联文件。")
            }
        }
    }

    private func validateLaunchAgent(path: URL, payload: URL) throws {
        guard path.deletingLastPathComponent().path == home.appendingPathComponent("Library/LaunchAgents").path else { return }
        guard let data = try? Data(contentsOf: payload),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty,
              label.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              !label.hasPrefix("com.apple."), !label.hasPrefix("cn.local.qingzhou") else {
            throw CleanError.refused("启动配置身份无法确认，或属于受保护任务。")
        }
        guard let loaded = launchAgentLoaded(label) else { throw CleanError.refused("无法确认后台任务状态，已停止操作。") }
        guard !loaded else { throw CleanError.refused("此后台任务仍已加载，请先在启动项中停用，再处理配置文件。") }
    }

    public func validate(_ file: CleanFile, checkRunning: Bool = true, method: TrashMoveMethod = .direct) throws {
        _ = try inspect(file, checkRunning: checkRunning, method: method)
    }

    private func inspect(_ file: CleanFile, checkRunning: Bool = true, method: TrashMoveMethod) throws -> (identity: TrashItemIdentity, owner: String?) {
        guard method != .finderInteractive || file.kind == .application else {
            throw CleanError.refused("访达回收只处理明确选择的应用本体，关联数据请单独检查。")
        }
        guard file.url.isFileURL else { throw CleanError.refused("只允许本机文件路径。") }
        let path = file.url.standardizedFileURL
        let appAllowed: Bool
        do { appAllowed = try validateDestination(path, ownerBundleID: file.ownerBundleID, kind: file.kind) }
        catch let error as CleanError { throw error }
        catch { throw TrashFailure.describe(error, at: path, stage: .validation, home: home) }
        guard (file.kind == .application) == appAllowed else {
            throw CleanError.refused("应用本体必须是扫描范围内的独立应用，请重新检查清单。")
        }
        let identity: TrashItemIdentity
        do { identity = try TrashItemIdentity.read(path) }
        catch { throw TrashFailure.describe(error, at: path, stage: .validation, home: home) }
        guard file.risk != .protected, !(file.ownerBundleID?.hasPrefix("com.apple.") ?? false), file.ownerBundleID != "cn.local.qingzhou" else {
            throw CleanError.refused("这是受保护的项目：\(path.lastPathComponent)")
        }
        let owner = appAllowed ? try validatedBundleID(at: path) : file.ownerBundleID
        try protection.validate(file, actualBundleID: appAllowed ? owner : nil)
        if appAllowed, let expected = file.ownerBundleID, owner != expected {
            throw CleanError.refused("应用身份已改变，请重新扫描后再操作。")
        }
        if method == .direct, !fm.isWritableFile(atPath: path.deletingLastPathComponent().path) {
            throw TrashFailure(stage: .validation, category: .fileAccess, path: path.path,
                               systemCodes: [], message: "原位置的父目录不可直接写入。可改用系统交互式回收，再由系统决定是否允许。")
        }
        if checkRunning {
            try self.checkRunning(path: path, ownerBundleID: owner)
            try validateLaunchAgent(path: path, payload: path)
        }
        return (identity, owner)
    }

    public func review(_ files: [CleanFile], method: TrashMoveMethod = .systemInteractive) throws -> TrashSelectionSnapshot {
        var identities: [String: TrashItemIdentity] = [:]
        for file in files {
            identities[file.url.standardizedFileURL.path] = try inspect(file, method: method).identity
        }
        return TrashSelectionSnapshot(identities: identities)
    }

    public func matchesFailedApplication(_ entry: TrashEntry, application app: AppRecord) -> Bool {
        guard !app.isProtected, entry.trashURL == nil, entry.error != nil, !entry.restored,
              entry.failure?.stage == .move,
              [.applicationManagement, .automation].contains(entry.failure?.category ?? .other),
              app.url.standardizedFileURL.path == entry.originalURL.standardizedFileURL.path,
              app.bundleID == entry.ownerBundleID, let expected = entry.itemIdentity,
              expected.birthSeconds != nil, expected.birthNanoseconds != nil else { return false }
        let file = CleanFile(url: app.url, kind: .application, reason: "核对失败记录", ownerBundleID: app.bundleID)
        guard let current = try? inspect(file, checkRunning: false, method: .finderInteractive) else { return false }
        return expected.matches(current.identity)
    }

    public func normalized(_ files: [CleanFile]) -> [CleanFile] {
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
            .sorted { $0.url.standardizedFileURL.pathComponents.count < $1.url.standardizedFileURL.pathComponents.count }
        var result: [CleanFile] = []
        for file in unique where !result.contains(where: { inside(file.url, root: $0.url) }) { result.append(file) }
        return result
    }

    private func validateTrashLocation(_ source: URL) throws {
        try rejectSymlinkPath(source)
        let source = source.standardizedFileURL
        var roots = [home.appendingPathComponent(".Trash")]
        if let testTrash { roots = [testTrash] }
        else if let volume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume {
            roots.append(volume.appendingPathComponent(".Trashes/\(getuid())"))
        }
        guard roots.contains(where: { source.deletingLastPathComponent().path == $0.standardizedFileURL.path }) else {
            throw CleanError.refused("恢复来源不是废纸篓内的有效文件。")
        }
    }

    private func validateTrashSource(_ source: URL, identity: TrashItemIdentity? = nil) throws {
        try validateTrashLocation(source)
        let current = try TrashItemIdentity.read(source)
        guard identity?.matches(current) != false else { throw CleanError.refused("废纸篓内的文件身份已改变，请手动核对，未移动文件。") }
    }

    private func verifyRecycled(original: URL, destination: URL, identity: TrashItemIdentity) throws {
        try validateTrashLocation(destination)
        var source = stat()
        guard lstat(original.path, &source) != 0 && errno == ENOENT else {
            throw CleanError.refused("系统回报已回收，但原位置仍存在项目或无法核实。请检查原位置和废纸篓。")
        }
        do {
            guard try identity.matches(TrashItemIdentity.read(destination)) else {
                throw CleanError.refused("系统返回的废纸篓文件身份不匹配，请手动核对。")
            }
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code) {
            // The original is gone, and the system supplied a location inside Trash. On machines
            // that deny inspecting Trash, require the captured identity before any later restore.
        }
    }

    private struct InteractiveMove {
        let destination: URL
        let cancelled: Bool
        let usedFinder: Bool
    }

    private func recycleInteractively(_ file: CleanFile, method: TrashMoveMethod, identity: TrashItemIdentity,
                                      additionalValidation: (() throws -> Void)?) throws -> InteractiveMove {
        let url = file.url.standardizedFileURL
        func useFinder() throws -> InteractiveMove {
            do { return InteractiveMove(destination: try finderRecycle(url), cancelled: false, usedFinder: true) }
            catch {
                let failure = TrashFailure.describe(error, at: url, stage: .move, home: home)
                guard failure.category == .applicationManagement else { throw failure }
                throw TrashFailure(stage: .move, category: .applicationManagement, path: url.path, systemCodes: failure.systemCodes,
                    message: "访达未获准移动此应用。请在访达的“显示简介”中检查锁定状态和所在磁盘的写入权限，或按开发者提供的卸载说明处理。")
            }
        }
        if method == .finderInteractive { return try useFinder() }

        let reply = try systemRecycle(url)
        let nativeFailure = reply.error.map { TrashFailure.describe($0, at: url, stage: .move, home: home) }
        if let moved = reply.destinations.first(where: { $0.key.standardizedFileURL.path == url.path })?.value {
            // A permission failure can include a proposed Trash URL even while the very same app remains in place.
            let deniedInPlace = file.kind == .application && nativeFailure?.category == .applicationManagement
                && (try? TrashItemIdentity.read(url)) == identity
            if !deniedInPlace {
                return InteractiveMove(destination: moved, cancelled: nativeFailure?.category == .cancelled, usedFinder: false)
            }
        }
        guard let nativeFailure else {
            throw CleanError.refused("系统未确认此项目的恢复位置，请核对原位置和废纸篓。")
        }
        let accessCategories: [TrashFailure.Category] = [.applicationManagement, .appData, .fileAccess]
        guard accessCategories.contains(nativeFailure.category) else { throw nativeFailure }

        var attempts = [("系统交互回收", nativeFailure)]
        func recheck(_ route: TrashMoveMethod) throws {
            let current = try inspect(file, method: route)
            try additionalValidation?()
            guard identity == current.identity && identity == (try? TrashItemIdentity.read(url)) else {
                throw CleanError.refused("文件身份已改变，未重试回收，请重新检查。")
            }
        }
        func record(_ label: String, _ error: Error, stage: TrashFailure.Stage) -> TrashFailure {
            let failure = TrashFailure.describe(error, at: url, stage: stage, home: home)
            attempts.append((label, failure))
            return TrashFailure(stage: failure.stage, category: failure.category, path: url.path,
                systemCodes: attempts.flatMap { label, item in item.systemCodes.map { label + "：" + $0 } },
                message: attempts.map { $0.0 + "未完成：" + $0.1.message }.joined(separator: "\n"))
        }

        do { try recheck(method) }
        catch { throw record("本进程回收", error, stage: .validation) }
        do {
            guard let moved = try directRecycle(url) else {
                throw CleanError.refused("本进程回收未返回恢复位置，请核对原位置和废纸篓。")
            }
            return InteractiveMove(destination: moved, cancelled: false, usedFinder: false)
        } catch {
            let failure = record("本进程回收", error, stage: .move)
            guard method == .systemWithFinderFallback, file.kind == .application,
                  failure.stage == .move, failure.category == .applicationManagement else { throw failure }
        }
        do { try recheck(.finderInteractive) }
        catch { throw record("访达回收", error, stage: .validation) }
        do { return try useFinder() }
        catch { throw record("访达回收", error, stage: .move) }
    }

    public func moveToTrash(_ files: [CleanFile], method: TrashMoveMethod = .direct, reviewed: TrashSelectionSnapshot? = nil, additionalValidation: (() throws -> Void)? = nil) throws -> TrashBatch {
        lock.lock(); defer { lock.unlock() }
        // Validate every requested item before removing overlapping selections. A protected child
        // must not silently disappear beneath a parent selection.
        guard !files.isEmpty else { throw CleanError.refused("请先选择文件。") }
        var identities: [String: TrashItemIdentity] = [:]
        var applicationOwners: [String: String] = [:]
        for file in files {
            try additionalValidation?()
            let current = try inspect(file, method: method)
            try reviewed?.require(current.identity, at: file.url)
            let path = file.url.standardizedFileURL.path
            identities[path] = current.identity
            if file.kind == .application {
                guard let owner = current.owner else { throw CleanError.refused("缺少应用身份，请重新检查。") }
                applicationOwners[path] = owner
            }
        }
        let normalizedFiles = normalized(files)
        let items = normalizedFiles.filter { $0.kind == .application } + normalizedFiles.filter { $0.kind != .application }
        var failedOwners = Set<String>()
        var cancelled = false
        var batches = try readHistory()
        var batch = TrashBatch(id: UUID(), date: Date(), entries: [])
        batches.insert(batch, at: 0)
        for file in items {
            let owner = applicationOwners[file.url.standardizedFileURL.path] ?? file.ownerBundleID
            var entry = TrashEntry(originalURL: file.url.standardizedFileURL, trashURL: nil, error: "准备移动；如操作中断，请检查原位置和废纸篓。", restored: false, ownerBundleID: owner)
            guard let identity = identities[entry.originalURL.path] else { throw CleanError.refused("无法核对待移动文件的身份。") }
            entry.itemIdentity = identity
            entry.kind = file.kind
            batch.entries.append(entry); batches[0] = batch
            try save(batches) // Persist intent before changing any user file.
            var stage = TrashFailure.Stage.validation
            do {
                if cancelled || (file.kind != .application && !failedOwners.isEmpty && (file.ownerBundleID.map(failedOwners.contains) ?? true)) {
                    throw TrashFailure(stage: .skipped, category: .other, path: file.url.path, systemCodes: [],
                                       message: cancelled ? "已取消本批操作，此项目未处理。" : "所属应用本体尚未移入废纸篓，此项数据已保留。")
                }
                let current = try inspect(file, method: method)
                try additionalValidation?()
                guard current.identity == identity && identity == (try? TrashItemIdentity.read(entry.originalURL)) else {
                    throw CleanError.refused("确认清单中的文件身份已改变，请重新检查。")
                }
                stage = .move
                if method != .direct {
                    let move = try recycleInteractively(file, method: method, identity: identity, additionalValidation: additionalValidation)
                    if move.cancelled { cancelled = true }
                    entry.trashURL = move.destination
                    try verifyRecycled(original: entry.originalURL, destination: move.destination, identity: identity)
                    if move.usedFinder { entry.recycledByFinder = true }
                } else if let testTrash {
                    try rejectSymlinkPath(testTrash)
                    try fm.createDirectory(at: testTrash, withIntermediateDirectories: true)
                    let destination = testTrash.appendingPathComponent(UUID().uuidString + "-" + file.url.lastPathComponent)
                    try fm.moveItem(at: entry.originalURL, to: destination); entry.trashURL = destination
                } else {
                    var destination: NSURL?
                    try fm.trashItem(at: entry.originalURL, resultingItemURL: &destination)
                    entry.trashURL = destination as URL?
                }
                entry.error = entry.trashURL == nil ? "已移入废纸篓，但系统未返回恢复位置；请在废纸篓中找回。" : nil
            } catch {
                let failure = TrashFailure.describe(error, at: file.url, stage: stage, home: home)
                entry.failure = failure; entry.error = failure.errorDescription
                if failure.category == .cancelled { cancelled = true }
            }
            if file.kind == .application, entry.trashURL == nil || entry.error != nil, let owner = entry.ownerBundleID { failedOwners.insert(owner) }
            batch.entries[batch.entries.count - 1] = entry; batches[0] = batch
            do { try save(batches) } catch {
                if let source = entry.trashURL, !exists(entry.originalURL) {
                    do {
                        try validateTrashSource(source, identity: entry.itemIdentity)
                        _ = try validateDestination(entry.originalURL, ownerBundleID: entry.ownerBundleID, payload: source, kind: entry.kind)
                        try fm.moveItem(at: source, to: entry.originalURL)
                    } catch {
                        throw CleanError.refused("记录写入失败，清理已停止。请检查当前文件位置：\(source.path)，原位置：\(entry.originalURL.path)")
                    }
                    throw CleanError.refused("记录写入失败，当前文件已放回原位置，清理已停止。此前完成的项目仍保留记录。")
                }
                throw CleanError.refused("记录写入失败，清理已停止。请检查原位置和系统废纸篓：\(entry.originalURL.path)")
            }
        }
        return batch
    }

    public func restore(batchID: UUID, entryIDs: Set<String>? = nil) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var batches = try readHistory()
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else { return 0 }
        var count = 0
        for entryIndex in batches[index].entries.indices {
            let entry = batches[index].entries[entryIndex]
            guard entryIDs?.contains(entry.id) != false, !entry.restored, let source = entry.trashURL else { continue }
            var moved = false
            do {
                guard entry.originalURL.isFileURL else { throw CleanError.refused("恢复目标必须是本机文件。") }
                try validateTrashSource(source, identity: entry.itemIdentity)
                let appAllowed = try validateDestination(entry.originalURL, ownerBundleID: entry.ownerBundleID, payload: source, kind: entry.kind)
                guard !exists(entry.originalURL) else { throw CleanError.refused("原位置已存在同名文件，未覆盖。") }
                let parent = entry.originalURL.deletingLastPathComponent()
                guard fm.fileExists(atPath: parent.path), fm.isWritableFile(atPath: parent.path) else {
                    throw CleanError.refused("原目录不存在或不可写，请手动恢复。")
                }
                let owner = appAllowed ? try validatedBundleID(at: source) : entry.ownerBundleID
                try checkRunning(path: entry.originalURL, ownerBundleID: owner)
                try validateLaunchAgent(path: entry.originalURL, payload: source)
                batches[index].entries[entryIndex].error = "准备恢复；如操作中断，请检查原位置和废纸篓。"
                try save(batches)
                try fm.moveItem(at: source, to: entry.originalURL)
                moved = true
                batches[index].entries[entryIndex].restored = true
                batches[index].entries[entryIndex].failure = nil
                batches[index].entries[entryIndex].error = nil
                try save(batches)
                count += 1
            } catch {
                if moved {
                    // If the journal cannot record success, return this item to its recorded Trash
                    // location. Never overwrite a newly created source or target.
                    do {
                        guard !exists(source) else { throw CleanError.refused("废纸篓位置已被占用。") }
                        try rejectSymlinkPath(source)
                        _ = try validateDestination(entry.originalURL, ownerBundleID: entry.ownerBundleID, kind: entry.kind)
                        try fm.moveItem(at: entry.originalURL, to: source)
                    } catch {
                        throw CleanError.refused("恢复记录写入失败。文件目前在原位置：\(entry.originalURL.path)。请手动检查，未覆盖其他文件。")
                    }
                    throw CleanError.refused("恢复记录写入失败，当前文件已放回废纸篓，恢复已停止。")
                }
                let failure = TrashFailure.describe(error, at: entry.originalURL, stage: .restore, home: home)
                batches[index].entries[entryIndex].failure = failure
                batches[index].entries[entryIndex].error = failure.errorDescription
                try save(batches)
            }
        }
        return count
    }
}
