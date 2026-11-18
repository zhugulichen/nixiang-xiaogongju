import Foundation
import Darwin

public struct InstallationComponent: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let evidence: String
    public let state: String?
}

public struct InstallationAuditReport: Sendable {
    public var components: [InstallationComponent] = []
    public var receipts: Set<String> = []
    public var notes: [String] = []
    public var uninstallers: [URL] = []
}

/// Reads installed-package receipts and third-party service registrations. Neither source grants deletion authority.
public struct InstallationAudit: Sendable {
    var systemLibrary = URL(fileURLWithPath: "/Library")
    var home = FileManager.default.homeDirectoryForCurrentUser
    var tool: @Sendable (String, [String]) throws -> ManagedProcess.Result = { try ManagedProcess.run($0, $1) }

    var signature: @Sendable (URL) -> ApplicationGroupService.Declaration? = { ApplicationGroupService.signedDeclaration(at: $0) }

    public init() {}

    /// With no selected application, inspect registered third-party services, including orphaned jobs that remain loaded.
    public func inspect(app: AppRecord?, originalURL: URL? = nil) throws -> InstallationAuditReport {
        let path = originalURL ?? app?.url
        var report = InstallationAuditReport()
        var receiptsByPath: [String: Set<String>] = [:]
        if let app, let path, !app.isProtected {
            try readReceipts(for: path, report: &report, paths: &receiptsByPath)
            if path.standardizedFileURL.path == app.url.standardizedFileURL.path {
                report.uninstallers = developerUninstallers(for: app)
            }
        }
        var components: [String: InstallationComponent] = [:]
        let info = app.flatMap { ApplicationMetadata.information(at: $0.url) } ?? [:]
        let declaredHelpers = Set((info["SMPrivilegedExecutables"] as? [String: String])?.keys.map { $0 } ?? [])
        let roots = [home.appendingPathComponent("Library/LaunchAgents")] +
            ["LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools"].map(systemLibrary.appendingPathComponent)
        for root in roots {
            let directory = root.lastPathComponent
            guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
                report.notes.append("跳过链接目录 " + root.path)
                continue
            }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            } catch {
                if (error as NSError).code != NSFileReadNoSuchFileError { report.notes.append(root.path + "，" + error.localizedDescription) }
                continue
            }
            for url in entries {
                try Task.checkCancellation()
                guard Self.regular(url) else { continue }
                let service = directory != "PrivilegedHelperTools"
                let config = service && url.pathExtension == "plist" ? Self.plist(url) : nil
                let label = service ? config?["Label"] as? String : url.lastPathComponent
                guard let label, Self.validID(label), !Self.reserved(label) else { continue }
                let program = (config?["Program"] as? String) ?? (config?["ProgramArguments"] as? [String])?.first
                var associations = (config?["AssociatedBundleIdentifiers"] as? [String]) ?? []
                if let one = config?["AssociatedBundleIdentifiers"] as? String { associations.append(one) }
                let normalized = url.standardizedFileURL.path
                var reasons = [String]()
                if let id = app?.bundleID, !id.isEmpty {
                    if associations.contains(id) { reasons.append("启动配置声明关联此应用标识") }
                    if label == id { reasons.append("组件标识与应用标识相同") }
                    if declaredHelpers.contains(label) { reasons.append("应用声明了此辅助程序标识") }
                }
                if let program, let path, program.hasPrefix("/"), !program.split(separator: "/").contains(".."),
                   URL(fileURLWithPath: program).standardizedFileURL.pathComponents.starts(with: path.standardizedFileURL.pathComponents) {
                    reasons.append("启动配置中的可执行文件位于此应用包")
                }
                if let ids = receiptsByPath[normalized] { reasons.append("安装收据 " + ids.sorted().joined(separator: "、")) }
                if app != nil && reasons.isEmpty { continue }
                if reasons.isEmpty {
                    let userAgent = root.standardizedFileURL.path == home.appendingPathComponent("Library/LaunchAgents").standardizedFileURL.path
                    reasons.append(directory == "PrivilegedHelperTools" ? "整机辅助工具，归属待核对" : (userAgent ? "当前用户启动配置，归属待核对" : "整机第三方启动配置，归属待核对"))
                }
                if let program { reasons.append("程序路径 " + program) }
                let state = service ? serviceState(label: label, system: directory == "LaunchDaemons") : nil
                components[normalized] = InstallationComponent(url: url, evidence: reasons.joined(separator: " · "), state: state)
            }
        }
        for (path, ids) in receiptsByPath where components[path] == nil {
            components[path] = InstallationComponent(url: URL(fileURLWithPath: path), evidence: "同一安装收据记录的包外文件，可能被其他程序共用：" + ids.sorted().joined(separator: "、"), state: nil)
        }
        report.components = components.values.sorted { $0.url.path < $1.url.path }
        return report
    }

    func developerUninstallers(for app: AppRecord) -> [URL] {
        guard let owner = signature(app.url), owner.identifier == app.bundleID, !owner.team.isEmpty else { return [] }
        let appNames = Set([app.name, app.url.deletingPathExtension().lastPathComponent].map { $0.lowercased() }.filter { !$0.isEmpty })
        let exactNames = appNames.reduce(into: Set<String>()) { names, name in
            names.formUnion(["uninstall " + name, name + " uninstaller", name + " uninstall", "卸载" + name, name + "卸载程序"])
        }
        var roots = ["Contents/Resources", "Contents/Helpers", "Contents/Library", "Contents/Resources/Uninstallers"].map(app.url.appendingPathComponent)
        let parent = app.url.deletingLastPathComponent()
        if parent.deletingLastPathComponent().lastPathComponent == "Applications" { roots.append(parent) }
        var eligible = Set<URL>()
        for root in roots where root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for candidate in entries where candidate.pathExtension.lowercased() == "app" {
                let name = candidate.deletingPathExtension().lastPathComponent.lowercased()
                let exact = exactNames.contains(name)
                let embedded = root.standardizedFileURL.path != parent.standardizedFileURL.path
                guard exact || (embedded && ["uninstall", "uninstaller", "卸载程序"].contains(name)),
                      candidate.standardizedFileURL.path == candidate.resolvingSymlinksInPath().standardizedFileURL.path,
                      let signed = signature(candidate), signed.team == owner.team, signed.identifier != owner.identifier else { continue }
                if exact || ["uninstall", "uninstaller"].contains(where: { signed.identifier.lowercased() == owner.identifier.lowercased() + "." + $0 }) {
                    eligible.insert(candidate)
                }
            }
        }
        return eligible.sorted { $0.path < $1.path }
    }

    private static func validID(_ label: String) -> Bool {
        label.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]{0,254}\z"#, options: .regularExpression) != nil
    }

    private static func reserved(_ id: String) -> Bool {
        ["com.apple", "cn.local.qingzhou", "com.qingzhou.cleaner", "local.qingzhou.cleaner", "org.qingzhou.cleaner"].contains {
            id.lowercased() == $0 || id.lowercased().hasPrefix($0 + ".")
        }
    }

    private static func regular(_ url: URL) -> Bool {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { return false }
        var attributes = stat()
        return lstat(url.path, &attributes) == 0 && attributes.st_mode & S_IFMT == S_IFREG
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard regular(url), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
              let bytes = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any]
    }

    private func serviceState(label: String, system: Bool) -> String {
        let domain = system ? "system" : "gui/" + String(getuid())
        guard let result = try? tool("/bin/launchctl", ["print", domain + "/" + label]) else { return "运行状态未知" }
        if result.status == 113 { return "未加载" }
        guard result.status == 0 else { return "运行状态未知" }
        // Read the service's top-level state, not the state of a nested resource coalition.
        if let state = result.output.split(separator: "\n").first(where: { $0.hasPrefix("\tstate = ") }) {
            return state.dropFirst("\tstate = ".count) == "running" ? "正在运行" : "已加载，当前未运行"
        }
        return "已加载，运行状态未知"
    }

    private func packageDictionary(_ arguments: [String]) throws -> [String: Any] {
        let result = try tool("/usr/sbin/pkgutil", arguments)
        guard result.status == 0, !result.truncated,
              let data = result.output.data(using: .utf8),
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw ManagementError.message("系统未返回完整的安装收据") }
        return dictionary
    }

    private func readReceipts(for app: URL, report: inout InstallationAuditReport, paths: inout [String: Set<String>]) throws {
        let probes = [app, app.appendingPathComponent("Contents/Info.plist")]
        for url in probes {
            try Task.checkCancellation()
            do {
                let file = try packageDictionary(["--file-info-plist", url.path])
                let rows = file["path-info"] as? [[String: Any]] ?? []
                for row in rows {
                    if let id = row["pkgid"] as? String, Self.validID(id), !Self.reserved(id) { report.receipts.insert(id) }
                }
            } catch { report.notes.append("无法核对收据归属 " + url.path) }
        }
        for id in report.receipts.sorted() {
            try Task.checkCancellation()
            do {
                let info = try packageDictionary(["--pkg-info-plist", id])
                guard info["pkgid"] as? String == id, let volume = info["volume"] as? String, volume == "/",
                      let location = info["install-location"] as? String, !location.split(separator: "/").contains("..")
                else { report.notes.append(id + " 的安装卷或位置无法核对"); continue }
                let base = URL(fileURLWithPath: volume, isDirectory: true).appendingPathComponent(location, isDirectory: true)
                let result = try tool("/usr/sbin/pkgutil", ["--only-files", "--files", id])
                guard result.status == 0 else { report.notes.append(id + " 文件清单读取失败"); continue }
                var lines = result.output.split(separator: "\n")
                if result.truncated {
                    if !lines.isEmpty { lines.removeLast() }
                    report.notes.append(id + " 的文件清单过长，仅核对已完整读取的行")
                }
                for name in lines {
                    try Task.checkCancellation()
                    guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { continue }
                    let url = base.appendingPathComponent(String(name)).standardizedFileURL
                    let components = url.pathComponents
                    guard !components.contains(where: { $0.lowercased().hasSuffix(".app") }),
                          !components.starts(with: app.standardizedFileURL.pathComponents),
                          [systemLibrary.pathComponents, ["/", "usr", "local"], ["/", "opt"]].contains(where: { components.starts(with: $0) }),
                          Self.regular(url) else { continue }
                    if paths.count >= 1000 && paths[url.path] == nil {
                        report.notes.append(id + " 包外文件超过 1000 项，当前只展示前 1000 项"); break
                    }
                    paths[url.path, default: []].insert(id)
                }
            } catch { report.notes.append("读取安装收据 " + id + " 失败") }
        }
    }
}
