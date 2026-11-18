import Foundation
import CoreServices
import Darwin

public enum ApplicationSortOrder: String, CaseIterable, Sendable {
    case name = "名称", size = "大小", lastUsed = "最近使用"
}

public enum ApplicationUsageFilter: Equatable, Sendable {
    case all, idle(days: Int), unknown
}

public enum ApplicationUsageService {
    public static func readLastUsed(for apps: [AppRecord]) async throws -> [String: Date] {
        try await readLastUsed(for: apps, now: Date()) { url in
            guard let indexed = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
            return MDItemCopyAttribute(indexed, kMDItemLastUsedDate) as? Date
        }
    }

    // The injected reader keeps tests independent of this machine's search index.
    static func readLastUsed(for apps: [AppRecord], now: Date, dateReader: (URL) -> Date?) async throws -> [String: Date] {
        try Task.checkCancellation()
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [:] }
        var dates: [String: Date] = [:]
        for app in apps {
            try Task.checkCancellation()
            await Task.yield()
            try Task.checkCancellation()
            let url = app.url.standardizedFileURL
            guard url.isFileURL, [nil, "", "localhost"].contains(url.host),
                  url.pathExtension.lowercased() == "app", !app.url.pathComponents.contains(".."),
                  !app.bundleID.isEmpty else { continue }
            let path = systemAliasPath(url.path)
            let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            guard let original = identity(of: directory),
                  identifier(in: directory, appURL: url) == app.bundleID else { continue }
            let date = dateReader(url)
            try Task.checkCancellation()
            // An index lookup is path-based. Do not attribute its result to a directory
            // or bundle identifier that changed while the lookup was in progress.
            let current = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard current >= 0 else { continue }
            defer { close(current) }
            guard identity(of: current) == original,
                  identifier(in: current, appURL: url) == app.bundleID,
                  let date = valid(date, now: now) else { continue }
            dates[app.id] = date
        }
        try Task.checkCancellation()
        return dates
    }

    public static func applications(_ apps: [AppRecord], lastUsed: [String: Date], order: ApplicationSortOrder,
                                    filter: ApplicationUsageFilter, query: String, now: Date = Date(),
                                    calendar: Calendar = .current) -> [AppRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff: Date?
        if case .idle(let days) = filter, days >= 0, now.timeIntervalSinceReferenceDate.isFinite,
           let date = calendar.date(byAdding: .day, value: -days, to: now), date.timeIntervalSinceReferenceDate.isFinite {
            cutoff = date
        } else { cutoff = nil }
        let filtered = apps.filter { app in
            guard query.isEmpty || app.name.localizedCaseInsensitiveContains(query) ||
                    app.bundleID.localizedCaseInsensitiveContains(query) || app.url.path.localizedCaseInsensitiveContains(query) else { return false }
            let date = valid(lastUsed[app.id], now: now)
            switch filter {
            case .all: return true
            case .unknown: return date == nil
            case .idle: return date.map { date in cutoff.map { date <= $0 } ?? false } ?? false
            }
        }
        return filtered.sorted { first, second in
            switch order {
            case .name: break
            case .size:
                if first.bytes != second.bytes { return first.bytes > second.bytes }
            case .lastUsed:
                switch (valid(lastUsed[first.id], now: now), valid(lastUsed[second.id], now: now)) {
                case let (first?, second?) where first != second: return first > second
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let comparison = first.name.localizedStandardCompare(second.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if first.url.path != second.url.path { return first.url.path < second.url.path }
            if first.bundleID != second.bundleID { return first.bundleID < second.bundleID }
            return first.version < second.version
        }
    }

    private static func valid(_ date: Date?, now: Date) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite, date <= now else { return nil }
        return date
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func identity(of descriptor: Int32) -> DirectoryIdentity? {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else { return nil }
        return DirectoryIdentity(device: attributes.st_dev, inode: attributes.st_ino)
    }

    private static func identifier(in directory: Int32, appURL: URL) -> String? {
        if let value = readInfo("Contents/Info.plist", in: directory) ?? readInfo("Info.plist", in: directory) {
            return value["CFBundleIdentifier"] as? String
        }
        // A mobile app wrapper has one OS-created internal alias. Resolve its text
        // relative to the held outer directory, then open only the exact internal path.
        var target = [CChar](repeating: 0, count: 4_096)
        let length = readlinkat(directory, "WrappedBundle", &target, target.count)
        guard length > 0, length < target.count,
              let link = String(bytes: target.prefix(length).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { return nil }
        let resolved = URL(fileURLWithPath: link, relativeTo: appURL).standardizedFileURL
        guard resolved.deletingLastPathComponent().path == appURL.appendingPathComponent("Wrapper").path,
              resolved.pathExtension.lowercased() == "app" else { return nil }
        let relative = "Wrapper/" + resolved.lastPathComponent + "/"
        let value = readInfo(relative + "Info.plist", in: directory) ?? readInfo(relative + "Contents/Info.plist", in: directory)
        return value?["CFBundleIdentifier"] as? String
    }

    private static func readInfo(_ path: String, in directory: Int32) -> [String: Any]? {
        let descriptor = openat(directory, path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var attributes = stat()
        let limit = 2_000_000
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 0, attributes.st_size <= limit,
              let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func systemAliasPath(_ path: String) -> String {
        for (alias, target) in [("/var", "private/var"), ("/tmp", "private/tmp")] {
            guard path.hasPrefix(alias + "/"),
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
                  destination == target || destination == "/" + target else { continue }
            return "/" + target + path.dropFirst(alias.count)
        }
        return path
    }
}
