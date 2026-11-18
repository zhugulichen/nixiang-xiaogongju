import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin

public enum ManagementError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct StartupEntry: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let label: String
    public let name: String
    public let isEnabled: Bool
    public let canToggle: Bool
    public let detail: String
    public init(url: URL, label: String, name: String, isEnabled: Bool, canToggle: Bool, detail: String) {
        self.url = url; self.label = label; self.name = name
        self.isEnabled = isEnabled; self.canToggle = canToggle; self.detail = detail
    }
}

public struct SystemServices: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    private var domain: String { "gui/\(getuid())" }
    private var userAgents: URL { home.appendingPathComponent("Library/LaunchAgents") }

    public func startupItems() -> [StartupEntry] {
        let directories = [userAgents, URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")]
        var domainResults: [String: ManagedProcess.Result] = [:]
        for targetDomain in Set(directories.map { Self.startupDomain(for: $0) }) {
            domainResults[targetDomain] = try? ManagedProcess.run("/bin/launchctl", ["print-disabled", targetDomain])
        }
        var entries: [StartupEntry] = []
        for directory in directories {
            let result = domainResults[Self.startupDomain(for: directory)]
            let stateReadable = result?.status == 0
            let overrides = Self.parseDisabled(result?.output ?? "")
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let label = plist["Label"] as? String, !label.isEmpty else { continue }
                let userOwned = directory == userAgents
                let mutable = userOwned && stateReadable && isSafeUserAgent(url, label: label)
                let enabled = !(overrides[label] ?? (plist["Disabled"] as? Bool ?? false))
                let executable = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                let name = executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? label
                let scope = userOwned ? "当前用户的启动代理" : (directory.lastPathComponent == "LaunchDaemons" ? "系统后台服务 · 仅查看" : "所有用户的启动代理 · 仅查看")
                let statusNote = stateReadable ? "启用表示允许启动，不代表当前正在运行。" : "无法读取启停状态；此处仅显示配置中的状态。"
                entries.append(StartupEntry(url: url, label: label, name: name, isEnabled: enabled,
                                            canToggle: mutable, detail: scope + "。" + statusNote + (executable.map { "\n" + $0 } ?? "")))
            }
        }
        return entries.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    public func setEnabled(_ enabled: Bool, for entry: StartupEntry) throws {
        guard entry.canToggle, isSafeUserAgent(entry.url, label: entry.label) else {
            throw ManagementError.message("只能修改当前用户目录下、由当前用户拥有的普通启动代理。系统项目和清舟自身受保护。")
        }
        guard let data = try? Data(contentsOf: entry.url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["Label"] as? String == entry.label else {
            throw ManagementError.message("启动配置已改变，请刷新列表后重试。")
        }
        let target = domain + "/" + entry.label
        let wasLoaded = (try ManagedProcess.run("/bin/launchctl", ["print", target])).status == 0
        let previousOverrides = try ManagedProcess.run("/bin/launchctl", ["print-disabled", domain])
        guard previousOverrides.status == 0 else { throw ManagementError.message("无法读取启动项状态。") }
        let previousEnabled = !(Self.parseDisabled(previousOverrides.output)[entry.label] ?? (plist["Disabled"] as? Bool ?? false))
        let change = try ManagedProcess.run("/bin/launchctl", [enabled ? "enable" : "disable", target])
        guard change.status == 0 else { throw ManagementError.message("系统未允许修改启动项：" + change.output) }
        let result: ManagedProcess.Result?
        if enabled && !wasLoaded { result = try ManagedProcess.run("/bin/launchctl", ["bootstrap", domain, entry.url.path]) }
        else if !enabled && wasLoaded { result = try ManagedProcess.run("/bin/launchctl", ["bootout", target]) }
        else { result = nil }
        if let result, result.status != 0 {
            _ = try? ManagedProcess.run("/bin/launchctl", [previousEnabled ? "enable" : "disable", target])
            throw ManagementError.message("启动配置修改未完成，已尝试恢复原启用状态。请刷新检查：" + result.output)
        }
        let verification = try ManagedProcess.run("/bin/launchctl", ["print-disabled", domain])
        guard verification.status == 0, Self.parseDisabled(verification.output)[entry.label] == !enabled else {
            throw ManagementError.message("系统未确认新的启用状态，请刷新检查。")
        }
    }

    private func isSafeUserAgent(_ url: URL, label: String) -> Bool {
        guard !label.contains("/"), !label.contains("\n"), !Self.isProtectedLabel(label), !label.isEmpty,
              url.pathExtension == "plist",
              url.standardizedFileURL.deletingLastPathComponent() == userAgents.standardizedFileURL,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        return true
    }

    static func startupDomain(for directory: URL, userID: uid_t = getuid()) -> String {
        directory.lastPathComponent == "LaunchDaemons" ? "system" : "gui/\(userID)"
    }

    static func isProtectedLabel(_ label: String) -> Bool {
        let protectedIDs = ["com.apple", "com.qingzhou", "cn.local.qingzhou"] + [Bundle.main.bundleIdentifier].compactMap { $0 }
        return protectedIDs.contains { label == $0 || label.hasPrefix($0 + ".") }
    }

    static func parseDisabled(_ text: String) -> [String: Bool] {
        guard let regex = try? NSRegularExpression(pattern: #"\"([^\"]+)\"\s*=>\s*(true|false|enabled|disabled)"#) else { return [:] }
        let ns = text as NSString
        var states: [String: Bool] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let state = ns.substring(with: match.range(at: 2))
            states[ns.substring(with: match.range(at: 1))] = state == "true" || state == "disabled"
        }
        return states
    }
}

enum ManagedProcess {
    struct Result { let status: Int32; let output: String; var truncated = false }
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ManagementError.message("系统操作超时，请稍后刷新重试。")
        }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 1_048_577) ?? Data()
        let output = String(decoding: data.prefix(1_048_576), as: UTF8.self)
        return Result(status: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                      truncated: data.count > 1_048_576)
    }
}

public enum UpdateStatus: String, Sendable, Codable {
    case available = "发现更新", upToDate = "未发现更新", noSource = "无公开更新源", failed = "检查未完成"
}

public struct UpdateInfo: Identifiable, Hashable, Sendable {
    public var id: String { appID }
    public let appID: String
    public let status: UpdateStatus
    public let latestVersion: String?
    public let url: URL?
    public let message: String
}

public enum UpdateService {
    private static let maximumFeedBytes = 2 * 1_024 * 1_024

    public static func check(app: AppRecord) async -> UpdateInfo {
        await check(app: app, configuration: .ephemeral)
    }

    static func check(app: AppRecord, configuration: URLSessionConfiguration) async -> UpdateInfo {
        guard let feedURL = app.feedURL else {
            return UpdateInfo(appID: app.id, status: .noSource, latestVersion: nil, url: nil,
                              message: "此应用未提供公开更新源。请在应用内或系统应用商店检查更新。")
        }
        guard safeWebURL(feedURL) else {
            return UpdateInfo(appID: app.id, status: .failed, latestVersion: nil, url: nil, message: "仅检查使用加密连接的公开更新源。")
        }
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: feedURL)
            request.setValue("Qingzhou/1.0", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  response.url.map(safeWebURL) == true else { throw ManagementError.message("更新源未返回有效结果。") }
            guard response.expectedContentLength <= maximumFeedBytes else { throw ManagementError.message("更新清单超过大小限制。") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumFeedBytes else { throw ManagementError.message("更新清单超过大小限制。") }
                data.append(byte)
            }
            return try parseFeed(data, app: app, sourceURL: response.url ?? feedURL)
        } catch {
            let detail: String
            if (error as? URLError)?.code == .timedOut {
                detail = "连接更新源超时，请稍后重试；尚未确认是否有更新。"
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                detail = "检查已取消；尚未确认是否有更新。"
            } else { detail = "无法完成检查：" + error.localizedDescription }
            return UpdateInfo(appID: app.id, status: .failed, latestVersion: nil, url: nil,
                              message: detail)
        }
    }

    static func parseFeed(_ data: Data, app: AppRecord, sourceURL: URL,
                          systemVersion: String = currentSystemVersion) throws -> UpdateInfo {
        guard data.count <= maximumFeedBytes,
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else {
            throw ManagementError.message("更新清单包含不支持的内容。")
        }
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else { throw ManagementError.message("更新清单格式无法识别。") }
        func incomplete(_ message: String) -> UpdateInfo {
            UpdateInfo(appID: app.id, status: .failed, latestVersion: nil, url: nil, message: message)
        }
        guard !app.bundleID.isEmpty, let info = ApplicationMetadata.information(at: app.url),
              info["CFBundleIdentifier"] as? String == app.bundleID else {
            return incomplete("无法核对当前安装的应用，请重新扫描应用后再检查。")
        }
        let installedBuild = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedDisplay = info["CFBundleShortVersionString"] as? String
        let candidates = delegate.items.filter { item in
            guard let version = item.displayVersion, isStableVersion(version),
                  item.channel.isEmpty || item.channel.lowercased() == "stable",
                  isStableTitle(item.title),
                  item.minimumBuild.isEmpty || installedBuild.map({ !$0.isEmpty && compareVersions(item.minimumBuild, $0) != .orderedDescending }) == true,
                  item.os.isEmpty || ["macos", "osx", "mac"].contains(item.os.lowercased()),
                  item.minimumOS.isEmpty || compareVersions(item.minimumOS, systemVersion) != .orderedDescending,
                  item.maximumOS.isEmpty || compareVersions(item.maximumOS, systemVersion) != .orderedAscending else { return false }
            let hardware = item.hardware.lowercased().split { $0 == "," || $0.isWhitespace }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            return hardware.isEmpty || hardware.contains { $0 == architecture || $0 == "universal" || $0 == "universal2" }
        }
        // Do not mix human-readable releases and internal build numbers on the same ordering scale.
        let latestByBuild = candidates.filter { !$0.version.isEmpty }.max { compareVersions($0.version, $1.version) == .orderedAscending }
        let latest = latestByBuild ?? candidates.max { compareVersions($0.shortVersion, $1.shortVersion) == .orderedAscending }
        guard let latest, let version = latest.displayVersion else {
            return incomplete("未找到同时符合当前系统和已安装版本条件的稳定记录，请在原应用内检查。")
        }
        let compareBuilds = !latest.version.isEmpty
        guard let installed = compareBuilds ? installedBuild : installedDisplay, !installed.isEmpty else {
            return incomplete("本机缺少与更新源对应的版本信息，无法确认是否有更新。")
        }
        let link = [latest.link, latest.releaseNotes, latest.download].filter { !$0.isEmpty }.compactMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL }.first(where: safeWebURL)
        let available = compareVersions(compareBuilds ? latest.version : latest.shortVersion, installed) == .orderedDescending
        let release = compareBuilds && version != latest.version ? "\(version)（构建 \(latest.version)）" : version
        let message: String
        if !available { message = "公开更新源中未发现更新的兼容稳定版。" }
        else if link == nil { message = "公开更新源列出 \(release)，但未提供可用的安全更新链接。请在原应用内检查。" }
        else { message = "公开更新源提供 \(release)。打开官方页面后按开发者说明更新。" }
        return UpdateInfo(appID: app.id, status: available ? .available : .upToDate, latestVersion: version, url: link, message: message)
    }

    static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
        func normalized(_ value: String) -> String {
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix("v") { value.removeFirst() }
            var components = value.split(separator: ".").map(String.init)
            while components.count > 1 && components.last == "0" { components.removeLast() }
            return components.joined(separator: ".")
        }
        return normalized(left).compare(normalized(right), options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isStableVersion(_ value: String) -> Bool {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        return normalized.range(of: #"^\d+(?:\.\d+)*(?:\s*\(\d+\))?$"#, options: .regularExpression) != nil
    }
    private static func isStableTitle(_ value: String) -> Bool {
        value.range(of: #"\b(?:beta|alpha|preview|nightly|canary|experimental|rc\d*|release\s+candidate)\b"#,
                    options: [.regularExpression, .caseInsensitive]) == nil
    }
    private static var currentSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    fileprivate static func safeWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
}

private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(UpdateService.safeWebURL) == true ? request : nil)
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    struct Enclosure {
        var version = "", shortVersion = "", download = "", os = ""
    }
    struct Item {
        var version = "", shortVersion = "", title = "", channel = "", link = "", releaseNotes = "", download = ""
        var minimumOS = "", maximumOS = "", minimumBuild = "", os = "", hardware = ""
        var enclosures: [Enclosure] = []
        var displayVersion: String? { shortVersion.isEmpty ? (version.isEmpty ? nil : version) : shortVersion }
    }
    var items: [Item] = []
    private var current: Item?
    private var elements: [String] = []
    private var text = ""
    private var itemDepth: Int?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = name.split(separator: ":").last.map(String.init) ?? name
        let parent = elements.last
        elements.append(name)
        if current == nil, name == "item", parent == "channel" {
            current = Item()
            itemDepth = elements.count
            return
        }
        guard let itemDepth, elements.count == itemDepth + 1 else { return }
        text = ""
        if name == "enclosure" {
            func attr(_ suffix: String) -> String? { attributes.first { $0.key.split(separator: ":").last == Substring(suffix) }?.value }
            if attr("deltaFrom") == nil {
                current?.enclosures.append(Enclosure(version: attr("version") ?? "", shortVersion: attr("shortVersionString") ?? "",
                                                     download: attributes["url"] ?? "", os: attr("os") ?? ""))
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let itemDepth, elements.count == itemDepth + 1 { text += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { elements.removeLast() }
        guard let itemDepth else { return }
        if elements.count == itemDepth, let item = current {
            if item.enclosures.isEmpty { items.append(item) }
            for enclosure in item.enclosures {
                var variant = item
                if !enclosure.version.isEmpty { variant.version = enclosure.version }
                if !enclosure.shortVersion.isEmpty { variant.shortVersion = enclosure.shortVersion }
                variant.download = enclosure.download
                variant.os = enclosure.os
                items.append(variant)
            }
            current = nil
            self.itemDepth = nil
            return
        }
        guard elements.count == itemDepth + 1 else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elements.last {
        case "version": current?.version = content
        case "shortVersionString": current?.shortVersion = content
        case "title": current?.title = content
        case "channel": current?.channel = content
        case "link": current?.link = content
        case "releaseNotesLink": current?.releaseNotes = content
        case "minimumSystemVersion": current?.minimumOS = content
        case "maximumSystemVersion": current?.maximumOS = content
        case "minimumUpdateVersion": current?.minimumBuild = content
        case "hardwareRequirements": current?.hardware = content
        default: break
        }
    }
}

@MainActor public enum DefaultAppService {
    public static func defaultApplication(forExtension extensionName: String) throws -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: try contentType(extensionName))
    }
    public static func applications(forExtension extensionName: String) throws -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: try contentType(extensionName)).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
    public static func setDefaultApplication(_ appURL: URL, forExtension extensionName: String) async throws {
        let type = try contentType(extensionName)
        guard appURL.isFileURL, appURL.pathExtension == "app", Bundle(url: appURL)?.bundleIdentifier != nil else {
            throw ManagementError.message("请选择已安装的有效应用程序。")
        }
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
        guard NSWorkspace.shared.urlForApplication(toOpen: type)?.resolvingSymlinksInPath() == appURL.resolvingSymlinksInPath() else {
            throw ManagementError.message("系统保留了原来的打开方式，未完成更改。")
        }
    }
    private static func contentType(_ extensionName: String) throws -> UTType {
        let value = extensionName.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !value.isEmpty, value.count <= 32, value.range(of: #"^[a-z0-9_+-]+$"#, options: .regularExpression) != nil,
              let type = UTType(filenameExtension: value), !type.isDynamic else {
            throw ManagementError.message("请输入系统已识别的文件扩展名，例如 pdf、jpg 或 txt。")
        }
        return type
    }
}
