import Foundation

public enum ApplicationLocationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Validates locations selected by a person without expanding the persistent cleanup scope.
public struct ApplicationLocationService: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    public static func contains(_ url: URL, in root: URL) -> Bool {
        let child = url.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return child.count > parent.count && child.starts(with: parent)
    }

    public static func applicationIsInScope(_ url: URL, roots: [URL]) -> Bool {
        roots.contains { contains(url, in: $0) }
    }

    public func application(at input: URL) throws -> AppRecord {
        let url = try realDirectory(input)
        guard url.pathExtension.lowercased() == "app" else {
            throw ApplicationLocationError.invalid("请拖入应用程序（名称以 .app 结尾），不能拖入普通文件或文件夹。")
        }
        try rejectTrashAndNestedApp(url)
        guard let app = AppScanner(home: home, applicationRoots: [url]).scanApplications().apps.first else {
            throw ApplicationLocationError.invalid("无法读取这个应用的基本信息：\(url.lastPathComponent)")
        }
        return app
    }

    public func scanRoot(at input: URL) throws -> URL {
        // Reject mount points before probing them: a disconnected disk or automount may block metadata reads.
        let mountedRoots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        guard !mountedRoots.contains(where: { $0.standardizedFileURL.path == input.standardizedFileURL.path }) else {
            throw ApplicationLocationError.invalid("请选择磁盘内专门存放应用的文件夹，不能添加整个磁盘。")
        }
        let url = try realDirectory(input)
        try rejectTrashAndNestedApp(url)
        guard url.pathExtension.lowercased() != "app" else {
            throw ApplicationLocationError.invalid("请选择存放应用的文件夹，不要选择应用程序本身。")
        }
        let tooBroad = ["/", "/Users", "/Volumes", "/private", "/var", "/tmp", home.path]
        let volumeRoot = try url.resourceValues(forKeys: [.volumeURLKey]).volume?.standardizedFileURL.resolvingSymlinksInPath()
        let protected = [URL(fileURLWithPath: "/System"), URL(fileURLWithPath: "/Library"), home.appendingPathComponent("Library"), URL(fileURLWithPath: "/usr"), URL(fileURLWithPath: "/bin"), URL(fileURLWithPath: "/sbin"), URL(fileURLWithPath: "/dev")]
        guard volumeRoot?.path != url.path, !tooBroad.contains(url.path), !protected.contains(where: { url.path == $0.path || Self.contains(url, in: $0) }) else {
            throw ApplicationLocationError.invalid("请选择专门存放应用的文件夹，不能添加整个磁盘、个人主目录或系统资源目录。")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ApplicationLocationError.invalid("无法读取此文件夹，请先确认它存在且有访问权限。")
        }
        return url
    }

    private func realDirectory(_ input: URL) throws -> URL {
        guard input.isFileURL, input.host == nil || input.host == "" || input.host == "localhost" else {
            throw ApplicationLocationError.invalid("只支持这台电脑上的应用和文件夹。")
        }
        let url = input.standardizedFileURL
        guard url.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            throw ApplicationLocationError.invalid("路径不存在、不是文件夹，或经过符号链接。请从访达中选择原始位置。")
        }
        // macOS may canonicalize its own /private aliases; reject all other ancestor links.
        var current = url
        while current.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let aliases = ["/tmp": "private/tmp", "/var": "private/var"]
                let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                guard let expected = aliases[current.path], destination == expected || destination == "/" + expected else {
                    throw ApplicationLocationError.invalid("不能通过符号链接添加应用或扫描文件夹。")
                }
            }
            current.deleteLastPathComponent()
        }
        return url
    }

    private func rejectTrashAndNestedApp(_ url: URL) throws {
        guard !url.pathComponents.contains(where: { [".Trash", ".Trashes"].contains($0) }) else {
            throw ApplicationLocationError.invalid("这个位置位于废纸篓中。请使用“自动清理提醒”，或先恢复应用再检查。")
        }
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            guard parent.pathExtension.lowercased() != "app" else {
                throw ApplicationLocationError.invalid("不能单独检查或添加应用内部的辅助组件，请选择外层应用。")
            }
            parent.deleteLastPathComponent()
        }
    }
}
