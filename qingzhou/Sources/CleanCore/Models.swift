import Foundation
import Darwin

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case application = "应用程序", cache = "缓存", preference = "偏好设置"
    case support = "应用数据", container = "容器数据", logs = "日志"
    case savedState = "窗口状态", webData = "网页数据", launchAgent = "启动配置"
    case installer = "下载的安装文件", extensionFile = "扩展组件", other = "其他文件"
}

public enum FileRisk: String, Codable, Sendable {
    case routine = "常规文件", personal = "可能含个人数据", protected = "受保护"
}

public struct CleanFile: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let kind: FileKind
    public let bytes: Int64
    public let reason: String
    public let risk: FileRisk
    public let defaultSelected: Bool
    public let ownerBundleID: String?
    public init(url: URL, kind: FileKind, bytes: Int64 = 0, reason: String,
                risk: FileRisk = .routine, defaultSelected: Bool = false, ownerBundleID: String? = nil) {
        self.url = url; self.kind = kind; self.bytes = bytes; self.reason = reason
        self.risk = risk; self.defaultSelected = defaultSelected; self.ownerBundleID = ownerBundleID
    }
}

public struct AppRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let bytes: Int64
    public let isProtected: Bool
    public let feedURL: URL?
    private let storeReceiptFound: Bool? // Optional for records saved by earlier versions.
    public var hasStoreReceipt: Bool { storeReceiptFound == true }
    public init(url: URL, name: String, bundleID: String, version: String, bytes: Int64 = 0,
                isProtected: Bool = false, feedURL: URL? = nil, hasStoreReceipt: Bool = false) {
        self.url = url; self.name = name; self.bundleID = bundleID; self.version = version
        self.bytes = bytes; self.isProtected = isProtected; self.feedURL = feedURL; self.storeReceiptFound = hasStoreReceipt ? true : nil
    }
}

/// Direct children of the scan root are at level one in a DirectoryEnumerator.
enum ApplicationInventoryTraversal {
    static let maximumApplicationLevel = 5
}

public struct ScanReport: Sendable {
    public var apps: [AppRecord]
    public var warnings: [String]
    public init(apps: [AppRecord], warnings: [String] = []) { self.apps = apps; self.warnings = warnings }
}

public enum DisplayFormat {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

public enum ApplicationMetadata {
    static func declaredFeed(in info: [String: Any]) -> URL? {
        guard let value = info["SUFeedURL"] as? String, let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    static func version(in info: [String: Any]) -> String {
        info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "未知"
    }

    static func matchesUpdateSnapshot(_ app: AppRecord) -> Bool {
        guard app.url.standardizedFileURL.path == app.url.resolvingSymlinksInPath().standardizedFileURL.path,
              let info = information(at: app.url), let id = info["CFBundleIdentifier"] as? String else { return false }
        return !id.isEmpty && id == app.bundleID && version(in: info) == app.version &&
            declaredFeed(in: info) == app.feedURL && hasNativeStoreReceipt(at: app.url) == app.hasStoreReceipt
    }

    /// A local distribution hint. The receipt contents are never read.
    public static func hasNativeStoreReceipt(at app: URL) -> Bool {
        let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
        let descriptor = open(receipt.path, O_EVTONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0
    }

    /// Wrapped iOS apps expose their metadata inside the same outer application's Wrapper folder.
    /// Only that exact, internal layout is accepted; arbitrary external symlink targets are refused.
    public static func information(at url: URL) -> [String: Any]? {
        func read(_ file: URL) -> [String: Any]? {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_000_000,
                  let data = try? Data(contentsOf: file), data.count <= 2_000_000 else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        if let info = read(url.appendingPathComponent("Contents/Info.plist")) ?? read(url.appendingPathComponent("Info.plist")) { return info }
        guard let target = wrappedBundle(in: url) else { return nil }
        return read(target.appendingPathComponent("Info.plist")) ?? read(target.appendingPathComponent("Contents/Info.plist"))
    }

    static func wrappedBundle(in url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let root = url.standardizedFileURL
        let wrapper = root.appendingPathComponent("Wrapper")
        let target = root.appendingPathComponent("WrappedBundle").resolvingSymlinksInPath().standardizedFileURL
        guard root.path == root.resolvingSymlinksInPath().path,
              wrapper.path == wrapper.resolvingSymlinksInPath().path,
              target.deletingLastPathComponent().path == wrapper.path,
              target.pathExtension.lowercased() == "app" else { return nil }
        return target
    }
}

/// The system's per-app user-script directory may contain handwritten scripts.
/// Team-prefixed and group identifiers can designate shared data and are excluded.
enum ApplicationScriptDirectory {
    static func accepts(_ identifier: String) -> Bool {
        let lowercase = identifier.lowercased()
        let excluded = ["group", "com.apple", "cn.local.qingzhou", "com.qingzhou.cleaner", "local.qingzhou.cleaner", "org.qingzhou.cleaner"]
        guard identifier.utf8.count <= 255,
              !excluded.contains(where: { lowercase == $0 || lowercase.hasPrefix($0 + ".") }),
              identifier.range(of: #"\A[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*){2,}\z"#, options: .regularExpression) != nil else { return false }
        let first = identifier.prefix(while: { $0 != "." })
        return first.count != 10 || first.contains(where: { !$0.isUppercase && !$0.isNumber })
    }
}

enum ApplicationSupportDirectory {
    /// Different channels have separate profiles under the same vendor directory.
    static let vendorSubpaths = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.brave.Browser": "BraveSoftware/Brave-Browser"
    ]
}
