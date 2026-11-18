import Foundation

public struct SkippedApplication: Codable, Hashable, Identifiable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let relatedIdentifiers: Set<String>
    public let paths: [URL]

    public init(bundleID: String, name: String, relatedIdentifiers: Set<String> = [], paths: [URL] = []) {
        self.bundleID = bundleID; self.name = name
        self.relatedIdentifiers = relatedIdentifiers.union([bundleID])
        self.paths = Array(Set(paths.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
    }
}

public struct ApplicationProtectionPolicy: Sendable {
    private let identifiers: Set<String>
    private let paths: [URL]
    private let configurationError: String?

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public init(records: [SkippedApplication] = [], configurationError: String? = nil) {
        identifiers = Set(records.flatMap { $0.relatedIdentifiers.union([$0.bundleID]) })
        paths = Array(Set(records.flatMap(\.paths).map(\.standardizedFileURL)))
        self.configurationError = configurationError ?? (Self.valid(records) ? nil : "跳过名单格式无法确认，清理已暂停。")
    }

    private static func valid(_ records: [SkippedApplication]) -> Bool {
        records.count <= 1_000 && records.allSatisfy { record in
            !record.name.isEmpty && record.name.count <= 1_000 &&
            record.relatedIdentifiers.union([record.bundleID]).allSatisfy {
                !$0.isEmpty && $0.count <= 255 && $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
            } && record.paths.count <= 10_000 && record.paths.allSatisfy {
                $0.isFileURL && [nil, "", "localhost"].contains($0.host) && $0.path.hasPrefix("/") && $0.path != "/"
            }
        }
    }

    public static func decode(_ data: Data?) throws -> [SkippedApplication] {
        guard let data else { return [] }
        guard data.count <= 4_194_304 else { throw Failure("跳过名单过大，清理已暂停。") }
        let records = try JSONDecoder().decode([SkippedApplication].self, from: data)
        guard valid(records) else { throw Failure("跳过名单格式无法确认，清理已暂停。") }
        return records
    }

    public static func decodePreference(_ value: Any?) throws -> [SkippedApplication] {
        guard let value else { return [] }
        guard let data = value as? Data else { throw Failure("跳过名单的设置类型无法确认，清理已暂停。") }
        return try decode(data)
    }

    public static func encode(_ records: [SkippedApplication]) throws -> Data {
        guard valid(records) else { throw Failure("跳过名单格式无法确认，未保存。") }
        let data = try JSONEncoder().encode(records)
        guard data.count <= 4_194_304 else { throw Failure("跳过名单过大，未保存。") }
        return data
    }

    private func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        let first = lhs.standardizedFileURL.pathComponents, second = rhs.standardizedFileURL.pathComponents
        return first.starts(with: second) || second.starts(with: first)
    }

    public func isBlocked(_ file: CleanFile, actualBundleID: String? = nil) -> Bool {
        let name = file.url.lastPathComponent
        let updaterCache = file.kind == .cache && (identifiers.contains(name) || [".ShipIt", ".sparkle", ".Squirrel"].contains {
            name.hasSuffix($0) && identifiers.contains(String(name.dropLast($0.count)))
        })
        return configurationError != nil || updaterCache || file.ownerBundleID.map(identifiers.contains) == true ||
            actualBundleID.map(identifiers.contains) == true || paths.contains { overlaps(file.url, $0) }
    }

    public func validate(_ file: CleanFile, actualBundleID: String? = nil) throws {
        if let configurationError { throw Failure(configurationError) }
        guard !isBlocked(file, actualBundleID: actualBundleID) else {
            throw Failure("此应用或关联路径在跳过名单中，不能清理。请先在名单中移除保护，再重新检查。")
        }
    }

    public func applying(to files: [CleanFile]) -> [CleanFile] {
        files.map { file in
            guard isBlocked(file) else { return file }
            return CleanFile(url: file.url, kind: file.kind, bytes: file.bytes,
                reason: "跳过名单保护：" + file.reason, risk: .protected,
                defaultSelected: false, ownerBundleID: file.ownerBundleID)
        }
    }
}
