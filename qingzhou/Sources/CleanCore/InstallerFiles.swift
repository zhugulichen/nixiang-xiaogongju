import Foundation
import Darwin

public struct InstallerScanReport: Sendable {
    public var files: [CleanFile] = []
    public var warnings: [String] = []
}

public struct InstallerFiles: Sendable {
    let downloads: URL
    var mountedImages: @Sendable () throws -> Set<String> = {
        let result = try ManagedProcess.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard result.status == 0,
              let info = try PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else {
            throw CocoaError(.fileReadUnknown)
        }
        return Set(images.compactMap { image in
            guard let path = image["image-path"] as? String, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        })
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        downloads = home.appendingPathComponent("Downloads").standardizedFileURL
    }

    func contains(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents, base = downloads.pathComponents
        guard url.isFileURL, ["", "localhost", nil].contains(url.host), parts.count > base.count, parts.starts(with: base),
              ["dmg", "pkg"].contains(url.pathExtension.lowercased()) else { return false }
        var parent = url.deletingLastPathComponent().standardizedFileURL
        while parent.path != downloads.path {
            guard !parent.lastPathComponent.hasPrefix("."),
                  (try? parent.resourceValues(forKeys: [.isPackageKey]).isPackage) == false else { return false }
            parent.deleteLastPathComponent()
        }
        return !url.lastPathComponent.hasPrefix(".")
    }

    // Confirm the file format without mounting an image or executing an installer.
    func matchesFormat(at payload: URL, for original: URL) -> Bool {
        guard contains(original), payload.standardizedFileURL.path == payload.resolvingSymlinksInPath().standardizedFileURL.path else { return false }
        let fd = open(payload.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return false }
        let image = original.pathExtension.lowercased() == "dmg"
        guard metadata.st_size >= (image ? 512 : 28) else { return false }
        var magic = [UInt8](repeating: 0, count: 4)
        let position = image ? metadata.st_size - 512 : 0
        return pread(fd, &magic, 4, position) == 4 && magic == Array((image ? "koly" : "xar!").utf8)
    }

    func canMoveImage(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dmg" else { return true }
        guard let mounted = try? mountedImages() else { return false }
        return !Self.isMounted(url, paths: mounted)
    }

    private static func isMounted(_ url: URL, paths: Set<String>) -> Bool {
        if paths.contains(url.standardizedFileURL.path) { return true }
        var source = stat()
        guard lstat(url.path, &source) == 0 else { return true }
        return paths.contains { path in
            var other = stat()
            return stat(path, &other) == 0 && source.st_dev == other.st_dev && source.st_ino == other.st_ino
        }
    }

    public func scan() -> InstallerScanReport {
        var report = InstallerScanReport()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey]
        guard downloads.path == downloads.resolvingSymlinksInPath().standardizedFileURL.path else {
            report.warnings = ["下载目录为链接，请在访达核实实际位置。"]; return report
        }
        var unreadable = Set<String>()
        guard let entries = FileManager.default.enumerator(at: downloads, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in
                unreadable.insert(url.path); return true
            }) else { report.warnings = ["无法读取下载目录：" + downloads.path]; return report }
        let mounted = try? mountedImages()
        for case let url as URL in entries {
            if Task.isCancelled { break }
            guard let metadata = try? url.resourceValues(forKeys: keys) else { unreadable.insert(url.path); continue }
            guard metadata.isSymbolicLink != true, url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                entries.skipDescendants(); continue
            }
            guard metadata.isRegularFile == true, ["dmg", "pkg"].contains(url.pathExtension.lowercased()) else { continue }
            if !FileManager.default.isReadableFile(atPath: url.path) {
                unreadable.insert(url.path); continue
            }
            guard matchesFormat(at: url, for: url) else { continue }
            let image = url.pathExtension.lowercased() == "dmg"
            let protected = image && (mounted.map { Self.isMounted(url, paths: $0) } ?? true)
            let detail = protected ? "映像已挂载或无法核对挂载状态，请弹出后刷新。" :
                (image ? "磁盘映像也可能含个人文件，请先确认用途。" : "下载的安装器文件，可在需要时保留重装。")
            report.files.append(CleanFile(url: url, kind: .installer, bytes: Int64(metadata.fileSize ?? 0),
                                          reason: detail, risk: protected ? .protected : .personal))
        }
        report.files.sort { $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes }
        report.warnings = unreadable.sorted().map { "未能读取：" + $0 }
        return report
    }
}
