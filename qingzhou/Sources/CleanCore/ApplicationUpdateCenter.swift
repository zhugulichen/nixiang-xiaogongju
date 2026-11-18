import Combine
import Foundation

public enum ApplicationUpdateSource: String {
    case developer = "开发者更新源", store = "苹果商店", manual = "应用内检查"
    public static func source(for app: AppRecord) -> Self {
        if app.hasStoreReceipt { return .store }
        return app.feedURL == nil ? .manual : .developer
    }
}

@MainActor public final class ApplicationUpdateCenter: ObservableObject {
    @Published public private(set) var results: [String: UpdateInfo] = [:]
    @Published public private(set) var checking = false
    @Published public private(set) var completed = 0
    @Published public private(set) var total = 0
    @Published public private(set) var ignored: [String: String]
    public let preferencesReadable: Bool
    private static let key = "ignoredUpdateApplications.v1"
    private let defaults: UserDefaults
    private let feedCheck: (AppRecord) async -> UpdateInfo
    private let storeCheck: (AppRecord, String) async -> UpdateInfo
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init(defaults: UserDefaults = .standard, feedCheck: @escaping (AppRecord) async -> UpdateInfo = UpdateService.check,
                storeCheck: @escaping (AppRecord, String) async -> UpdateInfo = StoreUpdateService.check) {
        self.defaults = defaults; self.feedCheck = feedCheck; self.storeCheck = storeCheck
        let saved = defaults.object(forKey: Self.key)
        self.ignored = saved as? [String: String] ?? [:]
        self.preferencesReadable = saved == nil || saved is [String: String]
    }

    public func isIgnored(_ app: AppRecord) -> Bool { ignored[app.bundleID] != nil }

    public func ignore(_ app: AppRecord, in inventory: [AppRecord]) {
        guard preferencesReadable, !checking, !app.bundleID.isEmpty else { return }
        ignored[app.bundleID] = app.name
        for copy in inventory where copy.bundleID == app.bundleID { results.removeValue(forKey: copy.id) }
        defaults.set(ignored, forKey: Self.key)
    }

    public func resume(bundleID: String) {
        guard preferencesReadable, !checking else { return }
        ignored.removeValue(forKey: bundleID); defaults.set(ignored, forKey: Self.key)
    }

    public func stop() {
        generation = UUID(); task?.cancel(); task = nil; checking = false
    }

    public func inventoryWillChange() {
        stop(); results = [:]; completed = 0; total = 0
    }

    public func developerTargets(in apps: [AppRecord]) -> [AppRecord] {
        apps.filter { !$0.isProtected && !isIgnored($0) && ApplicationUpdateSource.source(for: $0) == .developer }
    }

    public func checkFeeds(_ apps: [AppRecord]) {
        run(developerTargets(in: apps), check: feedCheck)
    }

    public func checkStore(_ app: AppRecord, region: String) {
        guard app.hasStoreReceipt, !isIgnored(app), StoreUpdateService.supports(region: region) else { return }
        let lookup = storeCheck
        run([app]) { await lookup($0, region) }
    }

    private nonisolated static func checked(_ app: AppRecord, using check: (AppRecord) async -> UpdateInfo) async -> UpdateInfo {
        let changed = UpdateInfo(appID: app.id, status: .failed, latestVersion: nil, url: nil,
                                 message: "本机应用的身份、版本或更新来源已变化，请重新扫描后检查。")
        guard !Task.isCancelled, ApplicationMetadata.matchesUpdateSnapshot(app) else { return changed }
        let result = await check(app)
        guard !Task.isCancelled, ApplicationMetadata.matchesUpdateSnapshot(app) else { return changed }
        return result
    }

    private func run(_ apps: [AppRecord], check: @escaping (AppRecord) async -> UpdateInfo) {
        guard preferencesReadable, !checking, !apps.isEmpty else { return }
        generation = UUID(); let ticket = generation
        for app in apps { results.removeValue(forKey: app.id) }
        total = apps.count; completed = 0; checking = true
        task = Task {
            await withTaskGroup(of: UpdateInfo.self) { group in
                var queue = apps.makeIterator()
                for _ in 0..<min(4, apps.count) {
                    if let app = queue.next() { _ = group.addTaskUnlessCancelled { await Self.checked(app, using: check) } }
                }
                while let result = await group.next() {
                    guard !Task.isCancelled, generation == ticket else { group.cancelAll(); break }
                    results[result.appID] = result; completed += 1
                    if let app = queue.next() { _ = group.addTaskUnlessCancelled { await Self.checked(app, using: check) } }
                }
            }
            guard generation == ticket else { return }
            checking = false; task = nil
        }
    }
}
