import SwiftUI
import AppKit
import CleanCore

enum Page: String, CaseIterable, Identifiable {
    case smartCleanup = "自动清理提醒"
    case applications = "应用卸载", leftovers = "疑似残留", caches = "缓存清理", startup = "启动项目"
    case batchUninstall = "批量卸载", installers = "下载安装包", network = "网络用量"
    case extensions = "扩展组件", updates = "检查更新", defaults = "默认打开方式", history = "清理记录", privacy = "权限与说明"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .smartCleanup: return "bell.badge"
        case .applications: return "square.grid.2x2"
        case .batchUninstall: return "square.stack.3d.up"
        case .network: return "network"
        case .leftovers: return "tray.full"
        case .installers: return "shippingbox"
        case .caches: return "sparkles"
        case .startup: return "power"
        case .extensions: return "puzzlepiece.extension"
        case .updates: return "arrow.triangle.2.circlepath"
        case .defaults: return "doc.badge.gearshape"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .smartCleanup: return "应用进入废纸篓后，在这里检查遗留文件。"
        case .applications: return "看清每一个关联文件，再决定如何清理。"
        case .batchUninstall: return "一次核对多个应用，合并路径后逐项清理。"
        case .installers: return "检查下载文件夹中的磁盘映像和安装器。"
        case .network: return "查看应用和进程的实际网络采样。"
        case .leftovers: return "未发现对应应用的文件只是候选，请核对后再选择。"
        case .caches: return "清理可重新生成的数据，给磁盘留一点余地。"
        case .startup: return "查看启动配置，管理当前用户的后台代理。"
        case .extensions: return "检查用户和共享目录中的插件、面板与服务。"
        case .updates: return "检查开发者更新源或查询苹果商店版本。"
        case .defaults: return "选择文件类型，设置你习惯使用的应用。"
        case .history: return "清理有记录。废纸篓中的文件可以尝试恢复。"
        case .privacy: return "扫描范围、系统权限和当前版本的能力边界。"
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var deletedContext: DeletedAppCandidate?
    @Published var sizeStatus = "容量为估算值 · 受限目录可能未纳入"
    @Published var sizing = false
    private var sizeTask: Task<Void, Never>?
    private var reviewedDeletion: DeletedAppCandidate?
    private var activeDeletionGuard: CleanupGuard?
    private var activeDeletionContext: DeletedAppCandidate?

    @Published var page: Page = .applications
    @Published var apps: [AppRecord] = []
    private var fileOwners: [String: ApplicationFileOwner] = [:]
    @Published var selectedAppID: String?
    @Published var files: [CleanFile] = []
    @Published var selectedFiles: Set<String> = []
    @Published var search = ""
    @Published var applicationSort: ApplicationSortOrder = .name
    @Published var usageFilterMode = "全部应用"
    @Published var idleDays = 90
    @Published private(set) var lastUsedDates: [String: Date] = [:]
    @Published private(set) var usageLoading = false
    private var usageTask: Task<Void, Never>?
    private var usageGeneration = UUID()
    @Published var busy = false
    @Published var modifyingFiles = false
    @Published var fileBusy = false
    @Published var activity = "准备扫描"
    @Published var warnings: [String] = []
    @Published var directoryStatuses: [DirectoryScanStatus] = []
    @Published var installerWarnings: [String] = []
    private var installerScan: Task<InstallerScanReport, Never>?
    @Published var lastScan: Date?
    @Published var cleanupFailure: TrashFailure?
    @Published private(set) var failedEntry: TrashEntry?
    @Published private(set) var bodiesForSeparateReview: [CleanFile] = []
    private var reviewedSelection: (snapshot: TrashSelectionSnapshot, files: [CleanFile])?
    private var finderRetryAfterScan: TrashEntry?
    @Published var offerCleanupHistory = false
    @Published var alert: String? { didSet { if alert == nil { offerCleanupHistory = false; cleanupFailure = nil; failedEntry = nil; bodiesForSeparateReview = [] } } }
    @Published var showConfirmation = false
    @Published var pendingCleanupDescription: String?
    @Published var pendingTrashMethod: TrashMoveMethod = .systemInteractive
    @Published var pendingFiles: [CleanFile] = []
    @Published var batches: [TrashBatch] = []
    @Published var startupItems: [StartupEntry] = []
    let updates = ApplicationUpdateCenter()
    @Published var scope = "卸载应用"
    @Published var batchAppIDs: Set<String> = []
    @Published var batchPlanReady = false
    @Published var batchWarnings: [String] = []
    private var batchTask: Task<Void, Never>?
    @Published var extraRoots: [String] = UserDefaults.standard.stringArray(forKey: "extraRoots") ?? []
    @Published var showScanRoots = false
    @Published var dropTargeted = false
    @Published private(set) var skippedApplications: [SkippedApplication] = []
    @Published private(set) var protectionError: String?
    @Published var cleanupSoundEnabled = UserDefaults.standard.object(forKey: "cleanupSoundEnabled") as? Bool ?? true
    private static let protectionKey = "skippedApplications.v1"
    private var openedApplicationURLs: [URL] = []
    private var pendingOpenURLs: [URL] = []
    private var scanningApplications = false
    private var generation = UUID()
    var builtInRoots: [URL] { [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications")] }
    var roots: [URL] { builtInRoots + extraRoots.map { URL(fileURLWithPath: $0) } }
    var scanner: AppScanner { AppScanner(applicationRoots: roots) }
    var protectionPolicy: ApplicationProtectionPolicy { ApplicationProtectionPolicy(records: skippedApplications, configurationError: protectionError) }
    var skippedBundleIDs: Set<String> { Set(skippedApplications.map(\.bundleID)) }
    var skippedRelatedIDs: Set<String> { Set(skippedApplications.flatMap { $0.relatedIdentifiers.union([$0.bundleID]) }) }
    var trash: TrashService { TrashService(applicationRoots: roots.filter { !$0.path.hasPrefix("/System") }, protection: protectionPolicy) }
    var selectedApp: AppRecord? { apps.first { $0.id == selectedAppID } }
    var selectedAppOutsideScanRoots: Bool { selectedApp.map { !ApplicationLocationService.applicationIsInScope($0.url, roots: roots) } ?? false }
    var shownApps: [AppRecord] {
        let filter: ApplicationUsageFilter = usageFilterMode == "闲置应用" ? .idle(days: idleDays) : (usageFilterMode == "使用时间未知" ? .unknown : .all)
        if usageLoading, filter != .all { return [] }
        return ApplicationUsageService.applications(apps, lastUsed: lastUsedDates, order: applicationSort, filter: filter, query: search)
    }
    var shownFiles: [CleanFile] { files.filter { search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search) || $0.kind.rawValue.contains(search) } }
    var selected: [CleanFile] { files.filter { selectedFiles.contains($0.id) } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.bytes } }

    init() { readProtectionSettings() }

    private func readProtectionSettings() {
        do {
            skippedApplications = try ApplicationProtectionPolicy.decodePreference(UserDefaults.standard.object(forKey: Self.protectionKey))
            protectionError = nil
        } catch { protectionError = "跳过名单无法读取，清理已暂停：" + error.localizedDescription }
    }

    func reloadProtectionSettings() {
        guard !busy, !modifyingFiles, !showConfirmation else { return }
        readProtectionSettings(); CleanupWatch.shared.refreshProtection(); scan()
    }

    private func saveProtection(_ records: [SkippedApplication]) throws {
        guard protectionError == nil else { throw CleanError.refused("现有跳过名单尚未确认，不能覆盖保存。请先重新读取名单。") }
        let data = try ApplicationProtectionPolicy.encode(records)
        UserDefaults.standard.set(data, forKey: Self.protectionKey)
        skippedApplications = records; protectionError = nil
        CleanupWatch.shared.refreshProtection()
    }

    func isSkipped(_ app: AppRecord) -> Bool { skippedRelatedIDs.contains(app.bundleID) }

    func skipApplication(_ app: AppRecord) {
        guard !busy, !modifyingFiles, !showConfirmation, !app.isProtected, !isSkipped(app), protectionError == nil else { return }
        busy = true; activity = "正在核对跳过名单的关联保护…"
        let scanner = self.scanner; let copies = apps.filter { $0.bundleID == app.bundleID }
        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    var paths = Set<URL>(), identifiers: Set<String> = [app.bundleID]
                    for copy in copies {
                        let current = try ApplicationLocationService().application(at: copy.url)
                        guard current.bundleID == app.bundleID else { throw CleanError.refused("应用身份已改变，请重新扫描。") }
                        paths.formUnion(scanner.relatedFiles(for: current, measureSizes: false).map(\.url))
                        identifiers.formUnion(scanner.relatedIdentifiers(for: current))
                    }
                    return SkippedApplication(bundleID: app.bundleID, name: app.name, relatedIdentifiers: identifiers, paths: Array(paths))
                }.value
                try saveProtection(skippedApplications + [record])
            } catch { alert = "未能加入跳过名单：" + error.localizedDescription }
            busy = false; scan()
        }
    }

    func removeSkippedApplication(_ bundleID: String) {
        guard !busy, !modifyingFiles, !showConfirmation, protectionError == nil else { return }
        do {
            try saveProtection(skippedApplications.filter { $0.bundleID != bundleID })
            scan()
        } catch { alert = "跳过名单未保存：" + error.localizedDescription }
    }

    func setCleanupSound(_ value: Bool) {
        cleanupSoundEnabled = value; UserDefaults.standard.set(value, forKey: "cleanupSoundEnabled")
    }

    func refreshUsage() {
        usageTask?.cancel(); lastUsedDates = [:]; usageGeneration = UUID()
        let ticket = usageGeneration; let snapshot = apps; usageLoading = true
        reconcileApplicationSelection()
        usageTask = Task {
            do {
                let dates = try await ApplicationUsageService.readLastUsed(for: snapshot)
                guard !Task.isCancelled, usageGeneration == ticket else { return }
                lastUsedDates = dates; usageLoading = false; reconcileApplicationSelection()
            } catch {
                guard usageGeneration == ticket else { return }
                usageLoading = false
            }
        }
    }

    func reconcileApplicationSelection() {
        guard page == .applications, !busy, !modifyingFiles, !showConfirmation else { return }
        if usageLoading, usageFilterMode != "全部应用" { selectedAppID = nil; loadApp(); return }
        guard !shownApps.contains(where: { $0.id == selectedAppID }) else { return }
        selectedAppID = shownApps.first?.id; loadApp()
    }

    func scan() {
        guard !busy, !modifyingFiles, !showConfirmation else { return }
        usageTask?.cancel(); lastUsedDates = [:]; usageGeneration = UUID(); usageLoading = true
        updates.inventoryWillChange()
        busy = true; scanningApplications = true; activity = "正在读取应用与占用空间…"
        let scanner = AppScanner(applicationRoots: roots + openedApplicationURLs); let records = skippedApplications
        Task {
            let (report, refreshed, owners) = await Task.detached(priority: .userInitiated) {
                let report = scanner.scanApplications()
                let refreshed = records.map { record in
                    var paths = Set(record.paths), identifiers = record.relatedIdentifiers
                    for app in report.apps where app.bundleID == record.bundleID {
                        paths.formUnion(scanner.relatedFiles(for: app, measureSizes: false).map(\.url))
                        identifiers.formUnion(scanner.relatedIdentifiers(for: app))
                    }
                    return SkippedApplication(bundleID: record.bundleID, name: record.name, relatedIdentifiers: identifiers, paths: Array(paths))
                }
                return (report, refreshed, scanner.fileOwners(of: report.apps))
            }.value
            if protectionError == nil, refreshed != records {
                do { try saveProtection(refreshed) } catch { protectionError = "跳过名单更新失败，清理已暂停：" + error.localizedDescription }
            }
            fileOwners = owners
            apps = report.apps; warnings = report.warnings; lastScan = Date(); busy = false; scanningApplications = false
            batchAppIDs.formIntersection(Set(apps.map(\.id)))
            batchAppIDs.subtract(apps.filter { isSkipped($0) }.map(\.id))
            activity = "找到 \(apps.count) 个应用"
            refreshUsage()
            if !pendingOpenURLs.isEmpty {
                let urls = pendingOpenURLs; pendingOpenURLs = []
                _ = openApplications(urls)
                return
            }
            if !shownApps.contains(where: { $0.id == selectedAppID }) { selectedAppID = shownApps.first?.id }
            loadPage()
            if let entry = finderRetryAfterScan {
                finderRetryAfterScan = nil
                if let app = finderRetryTarget(for: entry) {
                    reviewFinderRecovery(app, previous: entry)
                } else {
                    alert = "原应用已发生变化，请重新检查当前安装的应用。"
                }
            }
        }
    }

    func changePage(_ value: Page) {
        guard !modifyingFiles, !showConfirmation else { return }
        finderRetryAfterScan = nil
        page = value; search = ""; generation = UUID()
        if page == .applications, !shownApps.contains(where: { $0.id == selectedAppID }) { selectedAppID = shownApps.first?.id }
        loadPage()
    }

    func loadPage() {
        installerScan?.cancel(); installerScan = nil; installerWarnings = []
        generation = UUID(); let ticket = generation
        batchTask?.cancel(); batchPlanReady = false; batchWarnings = []
        sizeTask?.cancel(); sizing = false; sizeStatus = "容量为估算值 · 受限目录可能未纳入"
        selectedFiles = []; files = []; directoryStatuses = []
        if page == .smartCleanup { if let deletedContext { loadDeleted(deletedContext) } else { fileBusy = false }; return }
        if page == .history { batches = trash.history(); fileBusy = false; return }
        if [.privacy, .defaults, .updates, .network, .batchUninstall].contains(page) { fileBusy = false; return }
        if page == .applications { loadApp(); return }
        let scanner = self.scanner; let apps = self.apps; let page = self.page
        fileBusy = true
        if page == .installers {
            let task = Task.detached(priority: .userInitiated) { InstallerFiles().scan() }
            installerScan = task
            Task {
                let result = await task.value
                guard generation == ticket else { return }
                installerWarnings = result.warnings
                files = protectionPolicy.applying(to: result.files)
                installerScan = nil; fileBusy = false
            }
            return
        }
        Task {
            if page == .startup {
                let items = await Task.detached { SystemServices().startupItems() }.value
                guard generation == ticket else { return }; startupItems = items
            } else {
                let result = await Task.detached(priority: .userInitiated) {
                    scanner.recordingDirectories { scanner in
                        switch page {
                        case .leftovers: return scanner.leftovers(installed: apps)
                        case .caches: return scanner.caches()
                        case .extensions: return scanner.extensions()
                        default: return [CleanFile]()
                        }
                    }
                }.value
                guard generation == ticket else { return }
                directoryStatuses = result.directories
                files = protectionPolicy.applying(to: result.result)
            }
            fileBusy = false
        }
    }

    func selectApp(_ app: AppRecord) {
        guard !modifyingFiles, !showConfirmation else { return }
        selectedAppID = app.id; scope = "卸载应用"; loadApp()
    }
    func loadApp() {
        generation = UUID(); let ticket = generation
        sizeTask?.cancel(); sizing = false; sizeStatus = "容量为估算值 · 受限目录可能未纳入"
        files = []; selectedFiles = []; directoryStatuses = []
        guard let app = selectedApp,
              page != .applications || shownApps.contains(where: { $0.id == app.id }) else {
            if page == .applications { selectedAppID = nil }
            fileBusy = false; return
        }
        fileBusy = true; let scanner = self.scanner; let owners = fileOwners
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                scanner.recordingDirectories { $0.reviewedFiles(for: app, installed: owners) }
            }.value
            guard generation == ticket, selectedAppID == app.id else { return }
            directoryStatuses = result.directories
            files = protectionPolicy.applying(to: result.result.map { file in
                guard file.kind == .application, !app.isProtected,
                      !ApplicationLocationService.applicationIsInScope(app.url, roots: roots) else { return file }
                return CleanFile(url: file.url, kind: file.kind, bytes: file.bytes,
                                 reason: "应用位于扫描范围之外；添加其所在文件夹后才可卸载本体", risk: .protected,
                                 defaultSelected: false, ownerBundleID: file.ownerBundleID)
            })
            fileBusy = false; applyScope()
        }
    }

    func applyScope() {
        switch scope {
        case "仅清缓存": selectedFiles = Set(files.filter { $0.kind == .cache && $0.defaultSelected && $0.risk == .routine }.map(\.id))
        case "重置设置": selectedFiles = Set(files.filter { $0.risk != .protected && ($0.kind == .preference || ($0.defaultSelected && [.cache, .logs, .savedState].contains($0.kind))) }.map(\.id))
        default: selectedFiles = Set(files.filter { $0.defaultSelected && $0.risk != .protected }.map(\.id))
        }
    }

    func reviewSelection() {
        guard !busy, !modifyingFiles, !fileBusy, !showConfirmation, !selected.isEmpty else { return }
        guard page != .batchUninstall || batchPlanReady else { return }
        prepareReview(selected, bodiesOnly: false)
    }

    func prepareBodiesOnly(_ bodies: [CleanFile]) {
        guard !busy, !modifyingFiles, !showConfirmation, !bodies.isEmpty, bodies.allSatisfy({ $0.kind == .application }) else { return }
        prepareReview(bodies, bodiesOnly: true)
    }

    private func prepareReview(_ items: [CleanFile], bodiesOnly: Bool) {
        let service = trash
        reviewedSelection = nil
        do {
            reviewedSelection = (try service.review(items, method: .systemInteractive), items)
            pendingTrashMethod = .systemInteractive
            reviewedDeletion = page == .smartCleanup ? deletedContext : nil
            pendingCleanupDescription = bodiesOnly ? "本次只回收下列应用本体，保留全部关联数据。" :
                (page == .batchUninstall ? "批量检查 \(batchAppIDs.count) 个应用。请核对共享项目和个人数据。" : nil)
            pendingFiles = service.normalized(items); showConfirmation = true
        } catch {
            cleanupFailure = error as? TrashFailure
            if let failure = cleanupFailure, [.appData, .fileAccess].contains(failure.category),
               items.contains(where: { $0.kind != .application && $0.url.standardizedFileURL.path == failure.path }) {
                bodiesForSeparateReview = items.filter { $0.kind == .application }
            }
            alert = error.localizedDescription
        }
    }

    func confirmTrash() {
        guard showConfirmation, !busy, !modifyingFiles, !pendingFiles.isEmpty, let review = reviewedSelection else { return }
        let files = review.files; let snapshot = review.snapshot
        let context = reviewedDeletion; let moveMethod = pendingTrashMethod
        reviewedSelection = nil
        showConfirmation = false; busy = true; modifyingFiles = true
        activity = moveMethod == .finderInteractive ? "正在等待访达回收…" : "正在移入废纸篓…"
        let service = trash; let cleanupRoots = roots
        let gate = CleanupGuard(); activeDeletionGuard = context == nil ? nil : gate; activeDeletionContext = context
        Task {
            defer { modifyingFiles = false }
            do {
                if let context, !(await CleanupWatch.shared.isValid(context)) {
                    throw CleanError.refused("应用已恢复、重新安装或不再处于废纸篓中，请重新检查。")
                }
                let batch = try await Task.detached {
                    try service.moveToTrash(files, method: moveMethod, reviewed: snapshot, additionalValidation: {
                        if let context {
                            try gate.validate()
                            try DeletionMonitor.validateForCleanup(context, roots: cleanupRoots)
                        }
                    })
                }.value
                CleanupSoundFeedback.play(for: batch, method: moveMethod, enabled: cleanupSoundEnabled)
                // Do not suppress a later Finder deletion when our own attempt failed.
                let applicationPaths = Set(files.filter { $0.kind == .application }.map { $0.url.standardizedFileURL.path })
                await CleanupWatch.shared.suppressRecycledApplications(at: batch.entries.filter {
                    applicationPaths.contains($0.originalURL.standardizedFileURL.path) && $0.trashURL != nil && $0.error == nil
                }.compactMap(\.trashURL))
                let errors = batch.entries.compactMap(\.error)
                if let context, errors.isEmpty { CleanupWatch.shared.dismiss(context); if deletedContext?.id == context.id { deletedContext = nil } }
                let failures = batch.entries.filter { $0.failure != nil && !$0.restored }
                failedEntry = failures.first { $0.failure?.stage != .skipped } ?? failures.first
                cleanupFailure = failedEntry?.failure
                offerCleanupHistory = !errors.isEmpty
                if errors.isEmpty {
                    let viaFinder = batch.entries.filter { $0.recycledByFinder == true && $0.error == nil }.count
                    alert = "已将 \(batch.successCount) 项移入废纸篓，可在“清理记录”中恢复。"
                        + (viaFinder > 0 ? "\n其中 \(viaFinder) 个应用本体已由访达回收。" : "")
                        + (moveMethod == .finderInteractive ? "\n关联数据已保留，可在“疑似残留”中检查后再决定是否清理。" : "")
                }
                else { alert = "已移入废纸篓 \(batch.successCount) 项，未完成 \(errors.count) 项。\n" + (failedEntry?.error ?? errors.first ?? "") + "\n在清理记录中可查看各项原因并重新检查。" }
            } catch { cleanupFailure = error as? TrashFailure; alert = error.localizedDescription }
            activeDeletionGuard = nil; activeDeletionContext = nil
            pendingFiles = []; reviewedDeletion = nil
            modifyingFiles = false; busy = false; scan()
        }
    }

    func restore(_ batch: TrashBatch, entryID: String? = nil) {
        let ids = entryID.map { Set([$0]) }
        guard !busy else { return }; busy = true; modifyingFiles = true; activity = "正在恢复文件…"; let service = trash
        Task {
            defer { modifyingFiles = false }
            do {
                let count = try await Task.detached { try service.restore(batchID: batch.id, entryIDs: ids) }.value
                batches = service.history()
                let errors = batches.first { $0.id == batch.id }?.entries.filter { !$0.restored && $0.trashURL != nil && ids?.contains($0.id) != false }.compactMap(\.error) ?? []
                alert = "已恢复 \(count) 项。" + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
            } catch { alert = error.localizedDescription }
            modifyingFiles = false; busy = false; scan()
        }
    }

    func failedApplication(for entry: TrashEntry) -> AppRecord? {
        guard entry.error != nil, entry.trashURL == nil, !entry.restored else { return nil }
        if entry.originalURL.pathExtension.lowercased() == "app" {
            return apps.first { $0.url.standardizedFileURL.path == entry.originalURL.standardizedFileURL.path && $0.bundleID == entry.ownerBundleID }
        }
        let matches = apps.filter { $0.bundleID == entry.ownerBundleID }
        return matches.count == 1 ? matches[0] : nil
    }

    func finderRetryTarget(for entry: TrashEntry) -> AppRecord? {
        guard let app = failedApplication(for: entry), !app.isProtected, !isSkipped(app),
              trash.matchesFailedApplication(entry, application: app) else { return nil }
        return app
    }

    func reopenFailedApplication(_ app: AppRecord) {
        guard !busy, !modifyingFiles, !showConfirmation else { return }
        usageFilterMode = "全部应用"
        changePage(.applications); selectApp(app)
    }

    func reviewFinderRecovery(_ app: AppRecord, previous: TrashEntry? = nil) {
        if scanningApplications, let previous {
            finderRetryAfterScan = previous
            return
        }
        guard !busy, !modifyingFiles, !showConfirmation, !app.isProtected, !isSkipped(app) else { return }
        let file = CleanFile(url: app.url, kind: .application, bytes: app.bytes,
                             reason: "通过访达回收应用本体", ownerBundleID: app.bundleID)
        do {
            let service = trash
            let snapshot = try service.review([file], method: .finderInteractive)
            if let previous, !service.matchesFailedApplication(previous, application: app) {
                throw CleanError.refused("原应用已发生变化，请重新检查当前安装的应用。")
            }
            reviewedSelection = (snapshot, [file])
            reviewedDeletion = nil
            pendingTrashMethod = .finderInteractive
            pendingCleanupDescription = "仅将这个应用本体交给访达移入废纸篓。首次使用时系统会询问是否允许清舟控制访达，也可能要求身份验证。关联数据保留，可另行检查。"
            pendingFiles = [file]; showConfirmation = true
        } catch { alert = error.localizedDescription }
    }

    func openAutomationPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func toggleStartup(_ entry: StartupEntry) {
        guard !busy else { return }
        do { try protectionPolicy.validate(CleanFile(url: entry.url, kind: .launchAgent, reason: "启动配置", ownerBundleID: entry.label)) }
        catch { alert = error.localizedDescription; return }
        busy = true; activity = "正在修改启动状态…"
        Task {
            do { try await Task.detached { try SystemServices().setEnabled(!entry.isEnabled, for: entry) }.value }
            catch { alert = error.localizedDescription }
            busy = false; loadPage()
        }
    }

    func toggleBatch(_ app: AppRecord, selected: Bool) {
        guard !busy, !modifyingFiles, !showConfirmation, !app.isProtected, !isSkipped(app),
              ApplicationLocationService.applicationIsInScope(app.url, roots: roots) else { return }
        if selected { batchAppIDs.insert(app.id) } else { batchAppIDs.remove(app.id) }
        invalidateBatchPlan()
    }

    func clearBatch() {
        guard !busy, !modifyingFiles, !showConfirmation else { return }
        batchAppIDs = []; invalidateBatchPlan()
    }

    private func invalidateBatchPlan() {
        generation = UUID(); batchTask?.cancel(); sizeTask?.cancel()
        sizing = false; fileBusy = false; batchPlanReady = false; batchWarnings = []
        files = []; selectedFiles = []; sizeStatus = "容量为估算值 · 受限目录可能未纳入"
    }

    func analyzeBatch() {
        guard page == .batchUninstall, !busy, !modifyingFiles, !showConfirmation, !fileBusy, !batchAppIDs.isEmpty else { return }
        invalidateBatchPlan(); fileBusy = true
        let selected = apps.filter { batchAppIDs.contains($0.id) }; let installed = apps; let scanner = self.scanner
        let ticket = generation
        batchTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try scanner.recordingDirectories { try BatchCleanupPlanner.plan(apps: selected, installed: installed, scanner: $0) }
            }
            do {
                let (plan, directories) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == ticket, page == .batchUninstall else { return }
                directoryStatuses = directories
                files = protectionPolicy.applying(to: plan.files); batchWarnings = plan.warnings; batchPlanReady = true; fileBusy = false
                selectedFiles = Set(files.filter { $0.defaultSelected && $0.risk == .routine }.map(\.id))
            } catch {
                guard !Task.isCancelled, generation == ticket else { return }
                fileBusy = false; alert = error.localizedDescription
            }
        }
    }

    func addRoot(_ url: URL) {
        guard !busy, !modifyingFiles, !showConfirmation else { return }
        busy = true; activity = "正在验证扫描文件夹…"
        Task {
            do {
                let root = try await Task.detached(priority: .userInitiated) {
                    try ApplicationLocationService().scanRoot(at: url)
                }.value
                guard !roots.contains(where: { root.path == $0.path || ApplicationLocationService.contains(root, in: $0) }) else {
                    busy = false; alert = "这个文件夹已经包含在扫描范围内。"; return
                }
                extraRoots.append(root.path)
                busy = false; saveRootsAndScan()
            } catch {
                busy = false; alert = error.localizedDescription
            }
        }
    }

    func removeRoot(_ path: String) {
        guard !busy, !modifyingFiles, !showConfirmation, extraRoots.contains(path) else { return }
        extraRoots.removeAll { $0 == path }
        saveRootsAndScan()
    }

    private func saveRootsAndScan() {
        UserDefaults.standard.set(extraRoots, forKey: "extraRoots")
        CleanupWatch.shared.updateRoots(roots)
        scan()
    }

    /// Used both by Finder open events and the main window's file drop destination.
    @discardableResult
    func openApplications(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        guard !modifyingFiles, !showConfirmation else {
            alert = "请先完成或取消当前清理操作，再查看其他应用。"; return false
        }
        if scanningApplications {
            finderRetryAfterScan = nil
            pendingOpenURLs.append(contentsOf: urls)
            return true
        }
        guard !busy else { alert = "请等待当前操作完成，再拖入应用。"; return false }
        updates.inventoryWillChange()
        busy = true; activity = "正在读取拖入的应用…"
        generation = UUID(); let ticket = generation
        let scanner = self.scanner
        let unique = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([AppRecord], [String], [String: ApplicationFileOwner]) in
                var accepted: [AppRecord] = []; var messages: [String] = []
                for url in unique {
                    do { accepted.append(try ApplicationLocationService().application(at: url)) }
                    catch { messages.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
                return (accepted, messages, scanner.fileOwners(of: accepted))
            }.value
            busy = false
            fileOwners.merge(result.2) { _, updated in updated }
            for app in result.0 {
                if !openedApplicationURLs.contains(where: { $0.path == app.url.path }) { openedApplicationURLs.append(app.url) }
                apps.removeAll { $0.id == app.id }; apps.append(app)
            }
            activity = "已读取 \(result.0.count) 个应用"
            if let first = result.0.first, generation == ticket {
                page = .applications; usageFilterMode = "全部应用"; search = ""; refreshUsage(); selectApp(first)
            } else if generation == ticket {
                loadPage()
            }
            if !result.1.isEmpty { alert = result.1.joined(separator: "\n\n") }
        }
        return true
    }

    func reconcileDeletedCandidates(_ candidates: [DeletedAppCandidate]) {
        if let activeDeletionContext, !candidates.contains(where: { $0.id == activeDeletionContext.id }) { activeDeletionGuard?.invalidate() }
        guard let context = deletedContext, !candidates.contains(where: { $0.id == context.id }) else { return }
        activeDeletionGuard?.invalidate()
        deletedContext = nil
        if page == .smartCleanup && !busy {
            generation = UUID(); files = []; selectedFiles = []; fileBusy = false
            showConfirmation = false; pendingFiles = []; reviewedDeletion = nil
        }
    }

    func loadDeleted(_ candidate: DeletedAppCandidate) {
        guard !modifyingFiles, !showConfirmation else { return }
        page = .smartCleanup; search = ""; deletedContext = candidate
        generation = UUID(); let ticket = generation
        sizeTask?.cancel(); sizing = false; sizeStatus = "容量为估算值 · 受限目录可能未纳入"
        files = []; selectedFiles = []; directoryStatuses = []; fileBusy = true
        let scanner = self.scanner; let owners = fileOwners
        Task {
            guard await CleanupWatch.shared.isValid(candidate) else {
                if generation == ticket { deletedContext = nil; fileBusy = false; alert = "这个应用已恢复、重装或不再位于废纸篓。" }
                return
            }
            let app = candidate.app
            let relocated = AppRecord(url: candidate.trashURL, name: app.name, bundleID: app.bundleID, version: app.version)
            let result = await Task.detached {
                scanner.recordingDirectories { $0.reviewedFiles(for: relocated, installed: owners, originalURL: app.url).filter { $0.kind != .application } }
            }.value
            guard generation == ticket else { return }
            directoryStatuses = result.directories
            files = protectionPolicy.applying(to: result.result); fileBusy = false
            selectedFiles = Set(files.filter { $0.defaultSelected && $0.risk == .routine }.map(\.id))
        }
    }

    func measureFiles() {
        guard !sizing, !files.isEmpty else { return }
        sizing = true; sizeStatus = "正在完整统计，可取消…"
        let urls = files.map(\.url); let ticket = generation
        sizeTask = Task {
            let measurements = await SizeService.measure(urls)
            guard generation == ticket else { return }
            files = files.map { file in
                guard let result = measurements[file.url.standardizedFileURL.path] else { return file }
                return CleanFile(url: file.url, kind: file.kind, bytes: result.bytes, reason: file.reason, risk: file.risk, defaultSelected: file.defaultSelected, ownerBundleID: file.ownerBundleID)
            }
            // Reuse complete measurements in the application list and its size ordering.
            apps = apps.map { app in
                guard let result = measurements[app.url.standardizedFileURL.path], result.isComplete else { return app }
                return AppRecord(url: app.url, name: app.name, bundleID: app.bundleID, version: app.version,
                                 bytes: result.bytes, isProtected: app.isProtected, feedURL: app.feedURL, hasStoreReceipt: app.hasStoreReceipt)
            }
            let complete = measurements.count == urls.count && measurements.values.allSatisfy(\.isComplete)
            let missing = measurements.values.reduce(0) { $0 + $1.inaccessibleCount }
            sizeStatus = complete ? "已完整统计逻辑大小 · 实际释放空间可能不同" : "部分统计：已取消或有 \(missing) 项无法读取"
            sizing = false
        }
    }
    func cancelMeasurement() { sizeTask?.cancel() }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openAppManagement() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
    }
    func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
}

// Cross-thread cancellation is checked immediately before each file move.
final class CleanupGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        if !valid { throw CleanError.refused("自动清理候选已失效或监测设置已改变，清理已停止。") }
    }
}
