import Foundation

private struct MonitorValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

public struct DeletedAppCandidate: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let app: AppRecord
    public let trashURL: URL
    public let detectedAt: Date
    public init(id: String, app: AppRecord, trashURL: URL, detectedAt: Date) {
        self.id = id; self.app = app; self.trashURL = trashURL; self.detectedAt = detectedAt
    }
}

public struct MonitorPollResult: Sendable {
    /// Complete, currently valid queue. Consumers should replace their queue, not append blindly.
    public let candidates: [DeletedAppCandidate]
    public let warnings: [String]
    public let trackedApplicationCount: Int
    public let isBaselineReady: Bool
}

/// Read-only, identity-based monitoring. No mutation of applications or Trash occurs here.
public actor DeletionMonitor {
    private struct Snapshot {
        var app: AppRecord
        let identity: String
        let bookmark: Data?
        var firstMissing: Date?
        var firstInTrash: Date?
    }
    private var roots: [URL]
    private var ignored: Set<String>
    private var tracked: [String: Snapshot] = [:]
    private var queue: [String: DeletedAppCandidate] = [:]
    private var dismissed: Set<String> = []
    private var baselineReady = false
    private let home: URL
    private let explicitTrashRoots: [URL]?
    private let fm = FileManager.default
    private let stabilityInterval: TimeInterval = 2
    private static let ownIDs = ["cn.local.qingzhou", "com.qingzhou.cleaner", "local.qingzhou.cleaner", "org.qingzhou.cleaner"]

    public init(roots: [URL], ignoredBundleIDs: Set<String> = [],
                home: URL = FileManager.default.homeDirectoryForCurrentUser, trashRoots: [URL]? = nil) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.ignored = ignoredBundleIDs
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.explicitTrashRoots = trashRoots?.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    public func configure(roots: [URL], ignoredBundleIDs: Set<String>) {
        let updated = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        if Set(updated.map(\.path)) != Set(self.roots.map(\.path)) {
            self.roots = updated; reset()
        }
        ignored = ignoredBundleIDs
        queue = queue.filter { !ignored.contains($0.value.app.bundleID) }
        tracked = tracked.filter { !ignored.contains($0.value.app.bundleID) }
    }

    public func reset() {
        tracked = [:]; queue = [:]; dismissed = []; baselineReady = false
    }

    /// Forget only the application bodies that this process successfully recycled.
    /// The next installed inventory will track a restored copy again.
    public func suppressRecycledApplications(at trashURLs: [URL]) {
        for url in trashURLs {
            guard let identity = Self.fileIdentity(url) else { continue }
            tracked.removeValue(forKey: identity)
            queue.removeValue(forKey: identity)
        }
    }

    public func dismiss(candidateID: String) {
        dismissed.insert(candidateID); queue.removeValue(forKey: candidateID)
    }

    public func poll(now: Date = Date()) -> MonitorPollResult {
        var warnings: [String] = []
        let installed = inventory(warnings: &warnings)
        let installedIDs = Set(installed.values.map { $0.app.bundleID })
        let trashRoots = availableTrashRoots()
        if !baselineReady {
            tracked = installed; baselineReady = true
            return result(warnings: warnings, installedCount: installed.count)
        }
        var next = installed
        for identity in installed.keys { dismissed.remove(identity); queue.removeValue(forKey: identity) }
        // A restored/reinstalled application invalidates older reminders for its shared data.
        queue = queue.filter { !installedIDs.contains($0.value.app.bundleID) && !isExcluded($0.value.app.bundleID) }
        var trashIndex: [String: URL]?
        for (identity, var old) in tracked {
            guard installed[identity] == nil, !isExcluded(old.app.bundleID), !installedIDs.contains(old.app.bundleID) else { continue }
            old.firstMissing = old.firstMissing ?? now
            var located: URL?
            if let bookmark = old.bookmark {
                var stale = false
                located = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            if located.map({ Self.fileIdentity($0) == identity }) != true {
                if trashIndex == nil { trashIndex = indexTrash(trashRoots, warnings: &warnings) }
                located = trashIndex?[identity]
            }
            guard let location = located?.standardizedFileURL, Self.fileIdentity(location) == identity else {
                queue.removeValue(forKey: identity)
                if now.timeIntervalSince(old.firstMissing!) < 60 { next[identity] = old }
                continue
            }
            guard trashRoots.contains(where: { location.deletingLastPathComponent().path == $0.path }) else {
                // A confirmed move elsewhere must not be treated as deletion or monitored forever.
                queue.removeValue(forKey: identity); continue
            }
            guard location.path == location.resolvingSymlinksInPath().path,
                  let info = ApplicationMetadata.information(at: location),
                  info["CFBundleIdentifier"] as? String == old.app.bundleID else {
                queue.removeValue(forKey: identity)
                warnings.append("无法核实废纸篓中的应用身份，已跳过提醒：\(old.app.name)")
                continue
            }
            old.firstInTrash = old.firstInTrash ?? now
            next[identity] = old
            guard now.timeIntervalSince(old.firstInTrash!) >= stabilityInterval, !dismissed.contains(identity) else { continue }
            queue[identity] = DeletedAppCandidate(id: identity, app: old.app, trashURL: location, detectedAt: old.firstInTrash!)
        }
        tracked = next
        // Vanished trash entries (including emptied Trash) are never retained as actionable reminders.
        queue = queue.filter { identity, candidate in
            tracked[identity] != nil && Self.fileIdentity(candidate.trashURL) == identity
        }
        return result(warnings: warnings, installedCount: installed.count)
    }

    /// Re-check immediately before each cleanup mutation; reminders can become stale while reviewed.
    public nonisolated static func validateForCleanup(_ candidate: DeletedAppCandidate, roots: [URL], trashRoots: [URL]? = nil) throws {
        let fm = FileManager.default
        let trash = candidate.trashURL.standardizedFileURL
        let original = candidate.app.url.standardizedFileURL
        func refuse(_ text: String) -> MonitorValidationError { MonitorValidationError(message: text) }
        guard trash.isFileURL, original.isFileURL,
              trash.path == trash.resolvingSymlinksInPath().path,
              original.path == original.resolvingSymlinksInPath().path,
              fileIdentity(trash) == candidate.id,
              ApplicationMetadata.information(at: trash)?["CFBundleIdentifier"] as? String == candidate.app.bundleID else {
            throw refuse("废纸篓中的应用已经变化或无法读取，请重新检查后再清理。")
        }
        var permittedTrash = trashRoots ?? [fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
        if trashRoots == nil {
            for root in roots {
                if let volume = try? root.resourceValues(forKeys: [.volumeURLKey]).volume {
                    permittedTrash.append(volume.appendingPathComponent(".Trashes/\(getuid())"))
                }
            }
        }
        guard permittedTrash.contains(where: { trash.deletingLastPathComponent().path == $0.standardizedFileURL.resolvingSymlinksInPath().path }) else {
            throw refuse("此应用已不在已确认的废纸篓位置，已取消清理。")
        }
        guard (try? fm.attributesOfItem(atPath: original.path)) == nil else {
            throw refuse("应用原位置已恢复或出现新文件，已取消关联数据清理。")
        }
        guard !candidate.app.bundleID.hasPrefix("com.apple."), !ownIDs.contains(where: { candidate.app.bundleID == $0 || candidate.app.bundleID.hasPrefix($0 + ".") }) else {
            throw refuse("系统应用和清舟自身不能通过删除提醒清理。")
        }
        func checkApp(_ url: URL) throws {
            guard url.path == url.resolvingSymlinksInPath().path, fm.isReadableFile(atPath: url.path) else {
                throw refuse("无法完整核实应用目录中的项目，已取消清理：\(url.lastPathComponent)")
            }
            if ApplicationMetadata.information(at: url)?["CFBundleIdentifier"] as? String == candidate.app.bundleID {
                throw refuse("检测到该应用已恢复、重装或仍有其他副本，已取消关联数据清理。")
            }
        }
        for rawRoot in roots where !rawRoot.path.hasPrefix("/System/") {
            let root = rawRoot.standardizedFileURL
            guard root.isFileURL, root.path == root.resolvingSymlinksInPath().path else {
                throw refuse("监测目录已被替换为链接或不是本机目录，已取消清理。")
            }
            do {
                _ = try fm.attributesOfItem(atPath: root.path)
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { continue }
                throw refuse("无法核实监测目录，已取消清理：\(root.path)")
            }
            guard fm.isReadableFile(atPath: root.path) else { throw refuse("无法读取监测目录，已取消清理：\(root.path)") }
            if root.pathExtension.lowercased() == "app" {
                try checkApp(root); continue
            }
            var failed = false
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles],
                                               errorHandler: { _, _ in failed = true; return true }) else {
                throw refuse("无法核实监测目录，已取消清理：\(root.path)")
            }
            var examined = 0
            for case let url as URL in iterator {
                examined += 1
                if examined > 20_000 { throw refuse("监测目录过大，无法完整核实应用是否已恢复，已取消清理。") }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    // Safari is normally linked into /Applications. Read a link's target identity
                    // without traversing it, so a standard system alias cannot block every cleanup.
                    if url.pathExtension.lowercased() == "app" {
                        let target = url.resolvingSymlinksInPath()
                        guard let identifier = ApplicationMetadata.information(at: target)?["CFBundleIdentifier"] as? String else {
                            throw refuse("无法核实链接应用的身份，已取消清理：\(url.lastPathComponent)")
                        }
                        if identifier == candidate.app.bundleID { throw refuse("检测到该应用仍有链接副本，已取消关联数据清理。") }
                    }
                    iterator.skipDescendants(); continue
                }
                if url.pathExtension.lowercased() == "app" { iterator.skipDescendants(); try checkApp(url) }
                else if iterator.level >= ApplicationInventoryTraversal.maximumApplicationLevel { iterator.skipDescendants() }
            }
            if failed { throw refuse("部分应用位置无法读取，无法排除应用已恢复或重装，已取消清理。") }
        }
    }

    private func result(warnings: [String], installedCount: Int) -> MonitorPollResult {
        MonitorPollResult(candidates: queue.values.sorted { $0.detectedAt < $1.detectedAt },
                          warnings: Array(Set(warnings)).sorted(), trackedApplicationCount: installedCount,
                          isBaselineReady: baselineReady)
    }

    private func isExcluded(_ identifier: String) -> Bool {
        ignored.contains(identifier) || identifier == "com.apple" || identifier.hasPrefix("com.apple.") ||
        Self.ownIDs.contains { identifier == $0 || identifier.hasPrefix($0 + ".") }
    }

    private func inventory(warnings: inout [String]) -> [String: Snapshot] {
        var entries: [String: Snapshot] = [:]
        for root in roots where !root.path.hasPrefix("/System/") {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if root.pathExtension.lowercased() == "app" {
                append(root, to: &entries, warnings: &warnings); continue
            }
            guard isDirectory.boolValue, fm.isReadableFile(atPath: root.path) else {
                warnings.append("无法读取监测目录：\(root.path)"); continue
            }
            var failed = false
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                               options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else {
                warnings.append("无法读取监测目录：\(root.path)"); continue
            }
            var examined = 0
            for case let url as URL in iterator {
                examined += 1
                if examined > 20_000 { warnings.append("监测目录项目过多，部分深层位置未纳入：\(root.path)"); break }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    iterator.skipDescendants(); append(url, to: &entries, warnings: &warnings)
                } else if iterator.level >= ApplicationInventoryTraversal.maximumApplicationLevel { iterator.skipDescendants() }
            }
            if failed { warnings.append("监测目录中部分位置无法读取：\(root.path)") }
        }
        return entries
    }

    private func append(_ url: URL, to entries: inout [String: Snapshot], warnings: inout [String]) {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path,
              let info = ApplicationMetadata.information(at: url),
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty, !isExcluded(identifier),
              let identity = Self.fileIdentity(url) else { return }
        let app = AppRecord(url: url.standardizedFileURL,
                            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                            bundleID: identifier,
                            version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "未知")
        let bookmark = tracked[identity]?.bookmark ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        if bookmark == nil { warnings.append("部分应用无法建立位置书签；将尝试通过废纸篓文件身份核实。") }
        entries[identity] = Snapshot(app: app, identity: identity, bookmark: bookmark)
    }

    private func availableTrashRoots() -> [URL] {
        if let explicitTrashRoots { return explicitTrashRoots }
        var locations = [home.appendingPathComponent(".Trash")]
        for root in roots {
            if let volume = try? root.resourceValues(forKeys: [.volumeURLKey]).volume {
                locations.append(volume.appendingPathComponent(".Trashes/\(getuid())"))
            }
        }
        var seen = Set<String>()
        return locations.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
    }

    private func indexTrash(_ roots: [URL], warnings: inout [String]) -> [String: URL] {
        var index: [String: URL] = [:]
        for root in roots {
            do {
                for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) where url.pathExtension.lowercased() == "app" {
                    if let identity = Self.fileIdentity(url) { index[identity] = url }
                }
            } catch {
                let cocoaError = error as NSError
                if cocoaError.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code) { continue }
                warnings.append("无法读取废纸篓，自动识别可能遗漏。可在“权限与说明”中为清舟开启完全磁盘访问权限。")
            }
        }
        return index
    }

    private static func fileIdentity(_ url: URL) -> String? {
        guard url.isFileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        return "\(device.uint64Value):\(inode.uint64Value):\(created.timeIntervalSince1970.bitPattern)"
    }
}
