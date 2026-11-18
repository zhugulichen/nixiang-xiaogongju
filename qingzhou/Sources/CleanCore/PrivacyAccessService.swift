import Foundation
import Darwin
import Security
import SQLite3

public struct PrivacyAccessRecord: Equatable, Sendable {
    public let source: String
    public let target: String?
    public let status: String
    public let note: String?
    fileprivate let canReset: Bool
    fileprivate let requirement: Data?
    fileprivate let decision: Int
    fileprivate let reason: Int
    fileprivate let modified: Int64
}

public struct PrivacyAccessGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let records: [PrivacyAccessRecord]
    public var allowsReset: Bool { !records.isEmpty && records.allSatisfy(\.canReset) && records.contains { [2, 3].contains($0.decision) } }
}

public struct PrivacyAccessReport: Sendable {
    public let groups: [PrivacyAccessGroup]
    public let warnings: [String]
    public let requiresSystemSettings: Bool

    init(groups: [PrivacyAccessGroup], warnings: [String], requiresSystemSettings: Bool = false) {
        self.groups = groups
        self.warnings = warnings
        self.requiresSystemSettings = requiresSystemSettings
    }
}

public enum PrivacyAccessError: LocalizedError {
    case failed(String)
    public var errorDescription: String? { switch self { case .failed(let text): return text } }
}

/// Reads only rows belonging to the application under inspection. All changes go through the OS command.
public struct PrivacyAccessService: Sendable {
    private let databases: [URL]
    private let requiresSystemSettings: Bool
    private let match: @Sendable (URL, String, Data) -> Bool
    private let resetService: @Sendable (String, String) throws -> Void

    public init() {
        requiresSystemSettings = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        let relative = "Library/Application Support/com.apple.TCC/TCC.db"
        databases = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative),
                     URL(fileURLWithPath: "/" + relative)]
        match = { Self.matchesCode(at: $0, identifier: $1, requirement: $2) }
        resetService = { service, id in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, id]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            guard task.terminationReason == .exit && task.terminationStatus == 0 else {
                throw PrivacyAccessError.failed("系统未完成这项授权重置（状态码 \(task.terminationStatus)）。可在系统隐私设置核对。")
            }
        }
    }

    init(databases: [URL], match: @escaping @Sendable (URL, String, Data) -> Bool,
         reset: @escaping @Sendable (String, String) throws -> Void, operatingSystemMajorVersion: Int = 26) {
        requiresSystemSettings = operatingSystemMajorVersion >= 27
        self.databases = databases; self.match = match; self.resetService = reset
    }

    // Service names accepted by Apple's documented per-application tccutil reset interface.
    private static let titles = [
        "Accessibility": "辅助功能", "AddressBook": "通讯录", "AppleEvents": "自动控制其他应用",
        "AudioCapture": "系统音频采集", "BluetoothAlways": "蓝牙", "Calendar": "日历", "Camera": "相机",
        "DeveloperTool": "开发者工具", "EnergyKitGuidance": "能源使用指引", "ExternalCameraMedia": "外置相机媒体",
        "FileProviderDomain": "文件提供程序", "FileProviderPresence": "文件提供程序活动",
        "FocusStatus": "专注状态", "GameCenterFriends": "游戏中心好友", "HomeKit": "家庭数据",
        "ListenEvent": "输入监控", "MediaLibrary": "媒体资料库", "Microphone": "麦克风", "Motion": "运动数据",
        "Photos": "照片图库", "PhotosAdd": "添加照片", "PostEvent": "发送输入事件", "Reminders": "提醒事项",
        "RemoteDesktop": "远程桌面", "ScreenCapture": "屏幕录制", "Siri": "语音助手",
        "SpeechRecognition": "语音识别", "SystemPolicyAllFiles": "完全磁盘访问", "SystemPolicyAppBundles": "应用管理",
        "SystemPolicyAppData": "其他应用的数据", "SystemPolicyDesktopFolder": "桌面文件夹",
        "SystemPolicyDocumentsFolder": "文稿文件夹", "SystemPolicyDownloadsFolder": "下载文件夹",
        "SystemPolicyNetworkVolumes": "网络磁盘", "SystemPolicyRemovableVolumes": "可移动磁盘",
        "SystemPolicySysAdminFiles": "系统管理文件", "UserTracking": "应用跟踪", "VirtualMachineNetworking": "虚拟机网络",
        "VoiceBanking": "个人声音", "WebBrowserPublicKeyCredential": "浏览器通行密钥"
    ]

    public func inspect(_ app: AppRecord) -> PrivacyAccessReport {
        // macOS 27 replaced direct access to the local privacy database (Apple release note 90775556).
        if requiresSystemSettings {
            return PrivacyAccessReport(groups: [], warnings: [], requiresSystemSettings: true)
        }
        guard Self.isCurrent(app) else { return PrivacyAccessReport(groups: [], warnings: ["当前路径的应用身份无法核实，请重新扫描应用。"]) }
        var rows: [String: [PrivacyAccessRecord]] = [:]
        var warnings = [String]()
        // Multiple services often use the same requirement. Evaluate each distinct match once per report.
        var matches: [Data: Bool] = [:]
        for (index, path) in databases.enumerated() {
            let source = index == 0 ? "当前用户" : "全机"
            do {
                for (service, record) in try records(path: path, source: source, app: app, matches: &matches) {
                    rows[service, default: []].append(record)
                }
            } catch { warnings.append(source + "授权记录：" + error.localizedDescription) }
        }
        let groups = rows.map { service, records in
            PrivacyAccessGroup(id: service, title: Self.titles[service] ?? service, records: records)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return PrivacyAccessReport(groups: groups, warnings: warnings)
    }

    /// Re-read immediately before mutation. The OS scopes resets by bundle identifier, not file path.
    public func revoke(_ group: PrivacyAccessGroup, for app: AppRecord) throws -> PrivacyAccessReport {
        guard !requiresSystemSettings else {
            throw PrivacyAccessError.failed("当前系统的授权请在“隐私与安全性”中核对和调整。")
        }
        guard Self.titles[group.id] != nil, group.allowsReset, Self.isCurrent(app),
              let fresh = inspect(app).groups.first(where: { $0.id == group.id }), fresh == group else {
            throw PrivacyAccessError.failed("应用身份或授权记录已变化，请刷新后重新确认。")
        }
        try resetService(group.id, app.bundleID)
        return inspect(app)
    }

    private static func isCurrent(_ app: AppRecord) -> Bool {
        let id = app.bundleID
        guard !id.isEmpty, id.utf8.count <= 255, id.contains("."),
              id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
                  !part.isEmpty && part.utf8.allSatisfy { byte in
                      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
                  }
              }), app.url.isFileURL, app.url.pathExtension.lowercased() == "app",
              app.url.standardizedFileURL.path == app.url.resolvingSymlinksInPath().standardizedFileURL.path else { return false }
        return ApplicationMetadata.information(at: app.url)?["CFBundleIdentifier"] as? String == id
    }

    static func matchesCode(at app: URL, identifier: String, requirement: Data) -> Bool {
        let executableBundle = ApplicationMetadata.wrappedBundle(in: app) ?? app
        var code: SecStaticCode?, rule: SecRequirement?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executableBundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithData(requirement as CFData, [], &rule) == errSecSuccess, let rule,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any], fields[kSecCodeInfoIdentifier as String] as? String == identifier else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources).union(.noNetworkAccess), rule) == errSecSuccess
    }

    private func records(path: URL, source: String, app: AppRecord, matches: inout [Data: Bool]) throws -> [(String, PrivacyAccessRecord)] {
        var status = stat()
        if lstat(path.path, &status) != 0 {
            switch errno {
            case ENOENT, ENOTDIR: throw PrivacyAccessError.failed("未找到预期位置的授权记录文件。")
            case EACCES, EPERM: throw PrivacyAccessError.failed("系统拒绝访问。可在系统设置中核对授权。")
            default: throw PrivacyAccessError.failed("无法核对授权记录文件。可在系统设置中查看。")
            }
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw PrivacyAccessError.failed("授权记录路径不是普通文件。可在系统设置中查看。")
        }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard opened == SQLITE_OK, let handle, sqlite3_db_readonly(handle, "main") == 1 else {
            throw PrivacyAccessError.failed("无法以只读方式打开授权记录。可在系统设置中查看。")
        }
        sqlite3_busy_timeout(handle, 250)
        // An unknown schema must fail explicitly. Do not infer a negative decision from missing data.
        let sql = """
        SELECT service, auth_value, auth_reason, csreq, indirect_object_identifier, policy_id, last_modified, client_type
        FROM access WHERE (client_type = 0 AND client = ?1) OR (client_type = 1 AND client = ?2)
        ORDER BY service, indirect_object_identifier, client_type LIMIT 513
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PrivacyAccessError.failed("系统记录结构不受支持或读取受限，无法判断授权状态。")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, app.bundleID, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(stmt, 2, app.url.path, -1, transient) == SQLITE_OK else {
            throw PrivacyAccessError.failed("无法核对应用标识。")
        }
        var output = [(String, PrivacyAccessRecord)]()
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            guard output.count < 512, let key = sqlite3_column_text(stmt, 0), sqlite3_column_type(stmt, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(stmt, 2) == SQLITE_INTEGER else { throw PrivacyAccessError.failed("授权记录格式或数量超出可核实范围。") }
            let prefix = "kTCCService"
            let full = String(cString: key), service = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
            let value = Int(sqlite3_column_int(stmt, 1)), reason = Int(sqlite3_column_int(stmt, 2))
            let length = sqlite3_column_bytes(stmt, 3)
            let rule = (0 < length && length <= 65_536) ? sqlite3_column_blob(stmt, 3).map { Data(bytes: $0, count: Int(length)) } : nil
            let target = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let isManaged = sqlite3_column_type(stmt, 5) != SQLITE_NULL || ![2, 3].contains(reason)
            let byPath = sqlite3_column_int(stmt, 7) == 1
            let status: String
            switch value {
            case 0: status = "已拒绝"
            case 1: status = "待决定"
            case 2: status = "已允许"
            case 3: status = "有限授权"
            default: status = "未知授权值"
            }
            let valid = rule.map { data in
                if let cached = matches[data] { return cached }
                let valid = match(app.url, app.bundleID, data); matches[data] = valid; return valid
            } ?? false
            let note: String?
            if !valid { note = rule == nil ? "缺少可核对的签名条件" : "记录签名与当前应用未匹配" }
            else if byPath { note = "按文件路径登记，请在系统设置管理" }
            else if isManaged { note = "系统管理或决定来源未核实" }
            else if Self.titles[service] == nil { note = "此服务需在系统设置管理" }
            else { note = nil }
            let safe = note == nil && (0...3).contains(value) && full.hasPrefix(prefix)
            let item = PrivacyAccessRecord(source: source, target: target == "UNUSED" ? nil : target,
                status: valid ? status : "当前授权未核实", note: note, canReset: safe, requirement: rule,
                decision: value, reason: reason, modified: sqlite3_column_int64(stmt, 6))
            output.append((service, item))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw PrivacyAccessError.failed("读取未完成，请稍后刷新。") }
        return output
    }
}
