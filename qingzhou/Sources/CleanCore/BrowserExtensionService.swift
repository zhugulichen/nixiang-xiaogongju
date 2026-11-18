import Foundation
import Darwin

public enum ExtensionBrowser: String, CaseIterable, Sendable {
    case chrome = "谷歌浏览器", edge = "微软浏览器", brave = "Brave 浏览器", firefox = "火狐浏览器"
    public var bundleID: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .firefox: return "org.mozilla.firefox"
        }
    }
    public var managementAddress: String {
        switch self {
        case .chrome: return "chrome://extensions/"
        case .edge: return "edge://extensions/"
        case .brave: return "brave://extensions/"
        case .firefox: return "about:addons"
        }
    }
    fileprivate var folder: String {
        switch self {
        case .chrome: return "Google/Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .firefox: return "Firefox/Profiles"
        }
    }
}

public struct FirefoxPackageIdentity: Equatable, Sendable {
    fileprivate let device: dev_t, inode: ino_t, size: off_t, modifiedSeconds: Int, modifiedNanoseconds: Int
}

public enum ExtensionRemoval: Equatable, Sendable {
    case browserConfirmation, firefoxPackage(FirefoxPackageIdentity), unavailable
}

public struct BrowserExtensionRecord: Identifiable, Sendable {
    public var id: String { [browser.bundleID, profile, identifier].joined(separator: "/") }
    public let browser: ExtensionBrowser, profile: String, identifier: String
    fileprivate var registryFile: String? = nil
    public fileprivate(set) var removal: ExtensionRemoval = .unavailable
    public let name: String, version: String, state: String, source: String, note: String
    public let permissions: [String], sites: [String], optionalPermissions: [String], optionalSites: [String], scriptSites: [String]
}

public struct BrowserExtensionReport: Sendable {
    public fileprivate(set) var records: [BrowserExtensionRecord] = []
    public fileprivate(set) var warnings: [String] = []
    public fileprivate(set) var profiles = 0
}

public struct BrowserExtensionService: Sendable {
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    public func scan() throws -> BrowserExtensionReport {
        // Resolve only the caller-supplied home. Every path below it is opened without following symlinks.
        try Task.checkCancellation()
        guard let canonical = home.path.withCString({ realpath($0, nil) }) else {
            var report = BrowserExtensionReport(); report.warnings = ["无法读取当前用户的主目录。"]; return report
        }
        defer { free(canonical) }
        let support = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("Library/Application Support")
        return try ExtensionScan().run(support: support)
    }
}

private typealias Object = [String: Any]

private final class ExtensionScan {
    var result = BrowserExtensionReport()
    var remainingBytes = 64 * 1_024 * 1_024
    let unknown = "状态未确定", disabled = "有禁用记录", noDisable = "未见禁用记录"

    func warn(_ message: String) {
        if result.warnings.count < 32, !result.warnings.contains(message) { result.warnings.append(message) }
    }

    func run(support: URL) throws -> BrowserExtensionReport {
        for browser in ExtensionBrowser.allCases {
            try Task.checkCancellation()
            let root = support.appendingPathComponent(browser.folder)
            let profiles = children(root, limit: 4096).filter { name in
                browser == .firefox || name == "Default" || name.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil
            }.sorted()
            if profiles.count > 64 { warn("\(browser.rawValue) 配置数量超过本次读取上限。") }
            for profile in profiles.prefix(64) {
                try Task.checkCancellation()
                if result.records.count >= 4096 { warn("扩展总数超过本次读取上限。"); return result }
                let folder = root.appendingPathComponent(profile)
                guard let fd = descriptor(folder, directory: true) else { continue }
                close(fd); result.profiles += 1
                if browser == .firefox { try firefox(folder) }
                else { try chromium(browser, profile: folder) }
            }
        }
        result.records.sort { ($0.browser.rawValue, $0.profile, $0.name, $0.identifier) < ($1.browser.rawValue, $1.profile, $1.name, $1.identifier) }
        return result
    }

    private func descriptor(_ url: URL, directory: Bool) -> Int32? {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
        let fd = url.path.withCString { open($0, flags) }
        guard fd >= 0 else {
            if errno != ENOENT && errno != ENOTDIR { warn("无法读取 \(String(url.path.suffix(140)))，相应记录可能不全。") }
            return nil
        }
        return fd
    }

    private func children(_ folder: URL, limit: Int) -> [String] {
        guard let fd = descriptor(folder, directory: true) else { return [] }
        guard let dir = fdopendir(fd) else { close(fd); warn("无法列出 \(folder.lastPathComponent)。"); return [] }
        defer { closedir(dir) }
        var names = [String]()
        while !Task.isCancelled {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { warn("未能完整列出 \(folder.lastPathComponent)。") }
                break
            }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if name.hasPrefix(".") { continue }
            if names.count == limit { warn("\(folder.lastPathComponent) 条目过多，已截断。"); break }
            names.append(name)
        }
        return names
    }

    private func json(_ url: URL, limit: Int = 2 * 1_024 * 1_024) -> Object? {
        guard !Task.isCancelled, let fd = descriptor(url, directory: false) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= limit, info.st_size <= remainingBytes else {
            warn("\(String(url.path.suffix(100))) 为空、不是常规文件或超出读取上限。"); return nil
        }
        do {
            let count = Int(info.st_size)
            remainingBytes -= count
            let data = try handle.read(upToCount: count + 1) ?? Data()
            guard data.count == count, let object = try JSONSerialization.jsonObject(with: data) as? Object else {
                warn("\(url.lastPathComponent) 格式不完整或读取期间已改变。"); return nil
            }
            return object
        } catch { warn("\(String(url.path.suffix(100))) 无法解析。"); return nil }
    }

    func registration(of id: String, browser: ExtensionBrowser, in folder: URL, source: String) -> Bool? {
        guard let object = json(folder.appendingPathComponent(source), limit: 16 * 1_024 * 1_024) else { return nil }
        if browser == .firefox {
            guard let addons = object["addons"] as? [Object] else { return nil }
            return addons.contains { $0["id"] as? String == id && $0["type"] as? String == "extension" }
        }
        guard let extensions = object["extensions"] as? Object, let entries = extensions["settings"] as? Object else { return nil }
        if let entry = entries[id] as? Object, entry["path"] != nil || entry["manifest"] != nil { return true }
        for other in ["Preferences", "Secure Preferences"] where other != source {
            let url = folder.appendingPathComponent(other)
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { continue }
                return nil
            }
            guard let prefs = json(url, limit: 16 * 1_024 * 1_024) else { return nil }
            let secondary = ((prefs["extensions"] as? Object)?["settings"] as? Object)?[id] as? Object
            if secondary?["path"] != nil || secondary?["manifest"] != nil { return true }
        }
        return false
    }

    private func chromium(_ browser: ExtensionBrowser, profile: URL) throws {
        var settings = [String: Object](), sources = [String: String]()
        for filename in ["Preferences", "Secure Preferences"] {
            try Task.checkCancellation()
            guard let prefs = json(profile.appendingPathComponent(filename), limit: 16 * 1_024 * 1_024),
                  let section = prefs["extensions"] as? Object, let entries = section["settings"] as? Object else { continue }
            if entries.count > 4096 { warn("\(profile.lastPathComponent) 的扩展配置过多。") }
            for (id, value) in entries.prefix(4096) where validID(id) {
                guard let record = value as? Object, record["path"] != nil || record["manifest"] != nil else { continue }
                settings[id] = record; sources[id] = filename
            }
        }
        let extDir = profile.appendingPathComponent("Extensions")
        let diskIDs = Set(children(extDir, limit: 4096).filter(validID))
        for id in Set(settings.keys).union(diskIDs).sorted() {
            try Task.checkCancellation()
            if result.records.count >= 4096 { warn("扩展总数超过本次读取上限。"); return }
            let entry = settings[id]
            let extRoot = extDir.appendingPathComponent(id)
            var versionFolder: URL?
            var note = ""
            if let path = entry?["path"] as? String {
                let parts = path.components(separatedBy: "/")
                if parts.count == 2, parts[0] == id, validVersionFolder(parts[1]) {
                    versionFolder = extRoot.appendingPathComponent(parts[1])
                } else { note = "按浏览器登记的信息展示，未访问其引用的外部路径。" }
            } else if diskIDs.contains(id) {
                let versions = children(extRoot, limit: 256).filter(validVersionFolder)
                if versions.count == 1 { versionFolder = extRoot.appendingPathComponent(versions[0]); note = "仅找到一份本地清单，当前加载版本未确认。" }
                else if !versions.isEmpty { note = "发现多个版本目录，浏览器未指定当前版本。" }
                else { continue }
            }
            let direct = versionFolder.flatMap { json($0.appendingPathComponent("manifest.json")) }
            let cached = entry?["manifest"] as? Object
            guard let manifest = direct ?? cached else {
                if !note.isEmpty && entry == nil {
                    result.records.append(.init(browser: browser, profile: profile.lastPathComponent, identifier: id,
                        name: id, version: "未确定", state: unknown, source: "本地目录", note: note,
                        permissions: [], sites: [], optionalPermissions: [], optionalSites: [], scriptSites: []))
                } else { warn("\(profile.lastPathComponent) 中有扩展清单缺失或不可读取。") }
                continue
            }
            if direct == nil && note.isEmpty { note = "显示浏览器保存的清单副本。" }
            let required = strings(manifest["permissions"]), optional = strings(manifest["optional_permissions"])
            let location = entry?["location"] as? Int
            let source: String
            if location == 5 || location == 10 { source = "浏览器内置" }
            else if location == 7 || location == 9 { source = "由管理策略安装" }
            else if entry?["from_webstore"] as? Bool == true { source = "浏览器记录为商店安装" }
            else if location == 4 { source = "浏览器记录为解压加载" }
            else { source = entry == nil ? "本地目录" : "浏览器配置" }
            let scriptMatches = (manifest["content_scripts"] as? [Object] ?? []).prefix(256).flatMap { strings($0["matches"]) }
            result.records.append(.init(browser: browser, profile: profile.lastPathComponent, identifier: id,
                registryFile: sources[id], removal: location == 1 || location == 4 ? .browserConfirmation : .unavailable,
                name: localizedName(manifest, folder: versionFolder, fallback: id),
                version: short(manifest["version"]) ?? "未确定", state: chromeState(entry), source: source, note: note,
                permissions: required.filter { !isSite($0) }, sites: unique(required.filter(isSite) + strings(manifest["host_permissions"])),
                optionalPermissions: optional.filter { !isSite($0) }, optionalSites: unique(optional.filter(isSite) + strings(manifest["optional_host_permissions"])),
                scriptSites: unique(scriptMatches)))
        }
    }

    private func chromeState(_ entry: Object?) -> String {
        guard let entry else { return unknown }
        let state = entry["state"] as? Int
        if state == 0 { return disabled }
        if let reasons = entry["disable_reasons"] {
            if let array = reasons as? [Int] { return array.contains(where: { $0 != 0 }) ? disabled : noDisable }
            if let mask = reasons as? Int { return mask == 0 ? noDisable : disabled }
            return unknown
        }
        if state == 1 { return noDisable }
        return unknown
    }

    private func localizedName(_ manifest: Object, folder: URL?, fallback: String) -> String {
        guard let name = short(manifest["name"]) else { return fallback }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return name }
        guard let folder else { return fallback }
        let key = String(name.dropFirst(6).dropLast(2))
        var seen = Set<String>()
        let locales = ["zh_CN", "zh", short(manifest["default_locale"]) ?? "", "en"]
        for locale in locales where seen.insert(locale).inserted && locale.range(of: #"^[A-Za-z0-9_@-]{1,40}$"#, options: .regularExpression) != nil {
            guard let messages = json(folder.appendingPathComponent("_locales/\(locale)/messages.json")),
                  let item = messages.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value as? Object,
                  let message = short(item["message"]) else { continue }
            return message
        }
        return fallback
    }

    private func firefox(_ folder: URL) throws {
        guard let object = json(folder.appendingPathComponent("extensions.json"), limit: 16 * 1_024 * 1_024) else { return }
        guard let addons = object["addons"] as? [Object] else { warn("\(folder.lastPathComponent) 的火狐扩展记录格式未识别。"); return }
        var ids = Set<String>()
        for entry in addons where entry["type"] as? String == "extension" {
            try Task.checkCancellation()
            if result.records.count >= 4096 { warn("扩展总数超过本次读取上限。"); return }
            guard let id = short(entry["id"]), ids.insert(id).inserted else { continue }
            let required = entry["userPermissions"] as? Object ?? [:], requested = entry["requestedPermissions"] as? Object ?? [:]
            let optional = entry["optionalPermissions"] as? Object ?? [:]
            let disabledFlag = ["appDisabled", "userDisabled", "softDisabled", "embedderDisabled"].contains { entry[$0] as? Bool == true }
            let active = entry["active"] as? Bool
            let state: String
            if active == true && disabledFlag { state = unknown }
            else if disabledFlag { state = disabled }
            else if active == true { state = "记录为运行中" }
            else if active == false { state = "记录为未运行" }
            else { state = unknown }
            let locale = entry["defaultLocale"] as? Object
            result.records.append(.init(browser: .firefox, profile: folder.lastPathComponent, identifier: id,
                registryFile: "extensions.json", removal: firefoxRemoval(entry, folder: folder, id: id),
                name: short(locale?["name"]) ?? id, version: short(entry["version"]) ?? "未确定", state: state,
                source: short(entry["location"]) ?? "火狐配置", note: "",
                permissions: unique(strings(required["permissions"]) + strings(requested["permissions"])),
                sites: unique(strings(required["origins"]) + strings(requested["origins"])),
                optionalPermissions: strings(optional["permissions"]), optionalSites: strings(optional["origins"]), scriptSites: []))
        }
    }

    private func firefoxRemoval(_ entry: Object, folder: URL, id: String) -> ExtensionRemoval {
        guard entry["location"] as? String == "app-profile",
              ["isSystem", "isBuiltin", "isAppBuiltin", "hidden", "foreignInstall", "temporarilyInstalled", "locked"].allSatisfy({ entry[$0] as? Bool != true }),
              let telemetry = entry["installTelemetryInfo"] as? Object, let source = telemetry["source"] as? String,
              ["amo", "about:addons", "disco", "discovery", "aboutAddons", "file-url"].contains(source),
              FirefoxPackage.validIdentifier(id) else { return .unavailable }
        let package = folder.appendingPathComponent("extensions").appendingPathComponent(id + ".xpi")
        guard let registered = entry["path"] as? String, registered.hasPrefix("/"),
              URL(fileURLWithPath: registered).standardizedFileURL.path == package.standardizedFileURL.path,
              let identity = FirefoxPackage.identity(package) else { return .unavailable }
        return .firefoxPackage(identity)
    }

    private func short(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return String(text.prefix(512))
    }
    private func strings(_ value: Any?) -> [String] {
        guard let array = value as? [String] else { return [] }
        if array.count > 256 { warn("部分权限清单超过 256 项，仅显示前 256 项。") }
        return unique(array.prefix(256).compactMap { short($0) })
    }
    private func unique(_ values: [String]) -> [String] { Set(values).sorted() }
    private func isSite(_ value: String) -> Bool { value == "<all_urls>" || value.contains("://") }
    private func validID(_ value: String) -> Bool { value.utf8.count == 32 && value.utf8.allSatisfy { (97...112).contains($0) } }
    private func validVersionFolder(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{1,5}(?:\.[0-9]{1,5}){0,3}(?:_[0-9]{1,12})?$"#, options: .regularExpression) != nil
    }
}

public struct ExtensionRemovalError: LocalizedError {
    public var errorDescription: String? { message }
    let message: String
    init(_ message: String) { self.message = message }
}

private enum FirefoxPackage {
    static func validIdentifier(_ id: String) -> Bool {
        id.range(of: #"\A(?:[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+|\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\})\z"#, options: .regularExpression) != nil
            && id.utf8.count <= 180 && !id.hasPrefix(".")
    }

    static func identity(_ url: URL) -> FirefoxPackageIdentity? {
        var path = url.path
        // Foundation may shorten these two system directory aliases in a returned URL.
        for alias in ["/var", "/tmp"] where path.hasPrefix(alias + "/") {
            let canonical = "/private" + alias
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias)
            if target == canonical || target == String(canonical.dropFirst()) {
                path = "/private" + path
            }
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat(), signature = [UInt8](repeating: 0, count: 4)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              read(fd, &signature, 4) == 4, signature == [0x50, 0x4b, 0x03, 0x04] else { return nil }
        return .init(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }
}

extension BrowserExtensionRecord {
    public var detailAddress: String {
        browser == .firefox ? browser.managementAddress : browser.managementAddress + "?id=" + identifier
    }
}

extension BrowserExtensionService {
    public func targetURL(for row: BrowserExtensionRecord) -> URL {
        let folder = home.appendingPathComponent("Library/Application Support").appendingPathComponent(row.browser.folder)
            .appendingPathComponent(row.profile)
        return row.browser == .firefox
            ? folder.appendingPathComponent("extensions").appendingPathComponent(row.identifier + ".xpi")
            : folder.appendingPathComponent("Extensions").appendingPathComponent(row.identifier)
    }

    /// A missing, damaged or inaccessible registry cannot confirm that the browser removed anything.
    public func isRegistered(_ record: BrowserExtensionRecord) throws -> Bool? {
        guard let name = record.registryFile, let resolved = realpath(home.path, nil) else { return nil }
        defer { free(resolved) }
        try Task.checkCancellation()
        let folder = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("Library/Application Support")
            .appendingPathComponent(record.browser.folder).appendingPathComponent(record.profile)
        return ExtensionScan().registration(of: record.identifier, browser: record.browser, in: folder, source: name)
    }

    /// Capture a new scan after the confirmation sheet. Browser metadata may change with sync or policy.
    public func validateRemoval(_ record: BrowserExtensionRecord) throws {
        let report = try scan()
        guard record.removal != .unavailable,
              let current = report.records.first(where: { $0.id == record.id }),
              current.removal == record.removal, current.version == record.version, current.name == record.name else {
            throw ExtensionRemovalError("扩展的版本、来源或文件已变化，请刷新清单后再确认。")
        }
    }

    public func recycleFirefoxPackage(_ record: BrowserExtensionRecord, firefoxApp: URL, browserRunning: () -> Bool) throws -> URL {
        try recycleFirefoxPackage(record, browserRunning: browserRunning, policyPresent: {
            let domain = "org.mozilla.firefox" as CFString
            for key in ["EnterprisePoliciesEnabled", "ExtensionSettings", "Extensions"] {
                if CFPreferencesAppValueIsForced(key as CFString, domain) { return true }
            }
            let policyPaths = [
                firefoxApp.appendingPathComponent("Contents/Resources/distribution/policies.json").path,
                "/Library/Managed Preferences/org.mozilla.firefox.plist",
                "/Library/Managed Preferences/" + NSUserName() + "/org.mozilla.firefox.plist",
                "/etc/firefox/policies/policies.json"
            ]
            // Unknown access or policy contents require native browser management.
            return policyPaths.contains { path in var info = stat(); return lstat(path, &info) == 0 || errno != ENOENT }
        }, recycle: { url in
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            guard let destination else { throw ExtensionRemovalError("系统未返回废纸篓位置，请在访达核对扩展包。") }
            return destination as URL
        })
    }

    func recycleFirefoxPackage(_ record: BrowserExtensionRecord, browserRunning: () -> Bool,
                               policyPresent: () -> Bool, recycle: (URL) throws -> URL) throws -> URL {
        guard record.browser == .firefox, case let .firefoxPackage(expected) = record.removal,
              FirefoxPackage.validIdentifier(record.identifier), !record.profile.hasPrefix("."),
              !record.profile.contains("/"), !record.profile.isEmpty else { throw ExtensionRemovalError("此扩展由浏览器管理。") }
        guard !browserRunning() else { throw ExtensionRemovalError("请完整退出火狐后再移除扩展包。") }
        guard !policyPresent() else { throw ExtensionRemovalError("检测到火狐管理策略或无法核对策略，请使用火狐管理页。") }
        guard let resolved = realpath(home.path, nil) else { throw ExtensionRemovalError("无法核对主目录。") }
        defer { free(resolved) }
        let folder = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("Library/Application Support/Firefox/Profiles").appendingPathComponent(record.profile)
        let package = folder.appendingPathComponent("extensions").appendingPathComponent(record.identifier + ".xpi")
        try validateRemoval(record)
        // Firefox uses a POSIX write lock on .parentlock. Hold it across the file operation.
        let fd = open(folder.appendingPathComponent(".parentlock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK, 0600)
        guard fd >= 0 else { throw ExtensionRemovalError("无法锁定火狐配置，请完整退出火狐并重新检查。") }
        defer { close(fd) }
        var info = stat(), lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              fcntl(fd, F_SETLK, &lock) == 0, !browserRunning() else { throw ExtensionRemovalError("火狐配置仍在使用，移除已取消。") }
        try validateRemoval(record)
        guard !policyPresent(), FirefoxPackage.identity(package) == expected else { throw ExtensionRemovalError("当前扩展包或管理策略已改变，请重新检查。") }
        let destination = try recycle(package)
        guard lstat(package.path, &info) != 0, errno == ENOENT else { throw ExtensionRemovalError("原处仍有扩展包，请重新检查。") }
        guard destination.isFileURL, FirefoxPackage.identity(destination) == expected else {
            throw ExtensionRemovalError("原位置的扩展包已移走，但无法核实废纸篓中的文件身份。请在访达检查。")
        }
        return destination
    }
}
