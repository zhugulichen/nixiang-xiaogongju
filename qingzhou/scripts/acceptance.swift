import Foundation

@main struct Acceptance {
    static func createFixture(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CleanError.refused("无法生成安装文件测试样本") }
    }

    static func main() async throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let token = UUID().uuidString
        let identifier = "org.example.qingzhou.acceptance." + token
        let cache = home.appendingPathComponent("Library/Caches/" + identifier)
        let scripts = home.appendingPathComponent("Library/Application Scripts/" + identifier)
        let appRoot = home.appendingPathComponent("Applications")
        let app = appRoot.appendingPathComponent("清舟验收测试-" + token + ".app")
        let journalFolder = fm.temporaryDirectory.appendingPathComponent("qingzhou-acceptance-" + token).resolvingSymlinksInPath()
        let downloads = home.appendingPathComponent("Downloads/清舟验收-" + token)
        let package = downloads.appendingPathComponent("清舟测试.pkg")
        let image = downloads.appendingPathComponent("清舟测试.dmg")
        defer {
            try? fm.removeItem(at: downloads)
            try? fm.removeItem(at: cache)
            try? fm.removeItem(at: scripts)
            try? fm.removeItem(at: app)
            try? fm.removeItem(at: journalFolder)
        }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let payload = Data("清舟恢复验证：保留原始内容。".utf8)
        try payload.write(to: cache.appendingPathComponent("fixture.txt"))
        try payload.write(to: scripts.appendingPathComponent("fixture.txt"))
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "清舟验收测试", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        let metadata = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try metadata.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let scanner = AppScanner(applicationRoots: [appRoot])
        guard let record = scanner.scanApplications().apps.first(where: { $0.bundleID == identifier }) else { throw CleanError.refused("测试应用未被扫描发现") }
        let paths = Set([app.path, cache.path, scripts.path])
        let files = scanner.relatedFiles(for: record).filter { paths.contains($0.url.path) }
        guard files.count == paths.count, files.contains(where: { $0.url.path == scripts.path && !$0.defaultSelected && $0.risk == .personal }) else {
            throw CleanError.refused("测试应用、缓存及需单独勾选的脚本未正确关联")
        }
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try createFixture("/usr/bin/pkgbuild", ["--nopayload", "--identifier", identifier, "--version", "1", package.path])
        try createFixture("/usr/bin/hdiutil", ["create", "-quiet", "-format", "UDZO", "-fs", "HFS+", "-srcfolder", cache.path, image.path])
        let packageData = try Data(contentsOf: package), imageData = try Data(contentsOf: image)
        let installerPaths: Set<String> = [package.path, image.path]
        let installers = InstallerFiles().scan().files.filter { installerPaths.contains($0.url.path) }
        guard installers.count == 2, installers.allSatisfy({ !$0.defaultSelected && $0.risk == .personal }) else {
            throw CleanError.refused("真实安装器及未挂载的磁盘映像未被正确识别")
        }
        let service = TrashService(historyURL: journalFolder.appendingPathComponent("history.json"))
        let selected = files + installers
        let preview = try service.review(selected)
        let batch = try await Task.detached {
            try service.moveToTrash(selected, method: .systemInteractive, reviewed: preview)
        }.value
        let moved = batch.successCount == 5 && paths.union(installerPaths).allSatisfy { !fm.fileExists(atPath: $0) }
        let first = try service.restore(batchID: batch.id, entryIDs: [package.path])
        let restoredOnlyPackage = first == 1 && fm.fileExists(atPath: package.path) && !fm.fileExists(atPath: image.path)
        let remaining = try service.restore(batchID: batch.id)
        guard moved else { throw CleanError.refused("移入废纸篓验证失败。" + batch.entries.compactMap(\.error).joined(separator: "\n")) }
        guard restoredOnlyPackage, remaining == 4, try Data(contentsOf: package) == packageData, try Data(contentsOf: image) == imageData,
              try Data(contentsOf: cache.appendingPathComponent("fixture.txt")) == payload,
              try Data(contentsOf: scripts.appendingPathComponent("fixture.txt")) == payload,
              try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) == metadata else { throw CleanError.refused("恢复验证失败") }
        print("真实废纸篓验收通过。应用、缓存、脚本、安装器和磁盘映像回收 5 项。单独恢复安装器后恢复其余 4 项，逐项核对内容一致。")
    }
}
