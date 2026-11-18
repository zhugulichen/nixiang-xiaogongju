import Foundation

public struct BatchCleanupPlan: Sendable {
    public let apps: [AppRecord]
    public let files: [CleanFile]
    public let warnings: [String]
}

public enum BatchCleanupPlanner {
    public static func plan(apps: [AppRecord], installed: [AppRecord], scanner: AppScanner) throws -> BatchCleanupPlan {
        let apps = Dictionary(grouping: apps, by: \.id).compactMap { $0.value.first }.sorted { $0.id < $1.id }
        guard !apps.isEmpty else { throw CleanError.refused("请先选择要卸载的应用。") }
        let selectedIDs = Set(apps.map(\.id))
        var grouped: [String: [(CleanFile, AppRecord)]] = [:]
        var warnings: [String] = []
        for app in apps {
            try Task.checkCancellation()
            guard !app.isProtected, ApplicationLocationService.applicationIsInScope(app.url, roots: scanner.applicationRoots) else {
                throw CleanError.refused("“\(app.name)”受保护或位于扫描范围之外，不能加入批量卸载。")
            }
            let hasOtherCopy = installed.contains { $0.bundleID == app.bundleID && !selectedIDs.contains($0.id) }
            if hasOtherCopy { warnings.append("“\(app.name)”仍有未选择的同标识副本，关联数据仅供查看。") }
            for file in scanner.relatedFiles(for: app) {
                let protected = hasOtherCopy && file.kind != .application
                let item = CleanFile(url: file.url, kind: file.kind, bytes: file.bytes,
                    reason: app.name + "：" + (protected ? "仍被其他应用副本使用" : file.reason),
                    risk: protected ? .protected : file.risk, defaultSelected: !protected && file.defaultSelected,
                    ownerBundleID: file.ownerBundleID)
                grouped[file.url.standardizedFileURL.path, default: []].append((item, app))
            }
            try Task.checkCancellation()
        }
        // Read ownership candidates without walking their file contents for size estimates.
        // A remaining app may share an embedded helper or a named parent directory even
        // when its main bundle identifier differs from every selected app.
        var remainingPaths = Set<URL>()
        for app in installed where !selectedIDs.contains(app.id) {
            try Task.checkCancellation()
            remainingPaths.formUnion(scanner.relatedFiles(for: app, measureSizes: false).map { $0.url.standardizedFileURL })
            try Task.checkCancellation()
        }
        var hasRemainingOverlap = false
        var files = grouped.values.map { items -> CleanFile in
            let file = items[0].0
            let owners = Set(items.map { $0.1.bundleID })
            let shared = items.count > 1
            let path = file.url.standardizedFileURL
            let remainingOverlap = remainingPaths.contains {
                $0.path == path.path || ApplicationLocationService.contains($0, in: path) || ApplicationLocationService.contains(path, in: $0)
            }
            hasRemainingOverlap = hasRemainingOverlap || remainingOverlap
            let protected = remainingOverlap || items.contains { $0.0.risk == .protected } || owners.count > 1
            let reason = remainingOverlap ? "此路径或其父子目录仍与未选择的应用关联，仅供查看。" :
                (shared ? "多个所选应用关联到同一路径；已合并，需核实共享关系。" : file.reason)
            return CleanFile(url: file.url, kind: file.kind, bytes: file.bytes, reason: reason,
                risk: protected ? .protected : (shared ? .personal : file.risk),
                defaultSelected: !protected && !shared && file.defaultSelected, ownerBundleID: file.ownerBundleID)
        }
        try Task.checkCancellation()
        // Selecting a parent must never absorb a protected descendant during normalization.
        let protectedPaths = files.filter { $0.risk == .protected }.map(\.url)
        files = files.map { file in
            guard protectedPaths.contains(where: { ApplicationLocationService.contains($0, in: file.url) }) else { return file }
            return CleanFile(url: file.url, kind: file.kind, bytes: file.bytes,
                reason: "目录内包含受保护的共享项目，禁止整体清理。", risk: .protected,
                defaultSelected: false, ownerBundleID: file.ownerBundleID)
        }
        if grouped.values.contains(where: { $0.count > 1 }) { warnings.append("多个应用共同关联的文件不会默认选择；不同应用标识的共享路径仅供查看。") }
        if hasRemainingOverlap { warnings.append("已保护仍与未选择应用关联的文件及重叠目录，包含共享辅助程序和同名目录。") }
        return BatchCleanupPlan(apps: apps, files: files.sorted { $0.url.path < $1.url.path }, warnings: warnings)
    }
}
