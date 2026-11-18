import SwiftUI
import AppKit
import ServiceManagement
import CleanCore

@MainActor final class CleanupWatch: ObservableObject {
    static let shared = CleanupWatch()
    @Published var enabled = UserDefaults.standard.object(forKey: "watchEnabled") as? Bool ?? true
    @Published var candidates: [DeletedAppCandidate] = []
    @Published var status = "正在建立监测清单…"
    @Published var warnings: [String] = []
    @Published var ignored = UserDefaults.standard.dictionary(forKey: "ignoredApps") as? [String: String] ?? [:]
    @Published var loginStatus = "未设置"
    @Published var loginEnabled = false
    private var monitor: DeletionMonitor?
    private var loop: Task<Void, Never>?
    private var announced = Set<String>()
    private var reminder: NSPanel?
    private var reminderID: String?
    private var roots: [URL] = []
    private var excludedIDs: Set<String> { Set(ignored.keys).union(AppModel.shared.skippedRelatedIDs) }

    func start(roots: [URL]) {
        self.roots = roots
        monitor = DeletionMonitor(roots: roots, ignoredBundleIDs: excludedIDs)
        refreshLoginStatus()
        beginLoop()
    }
    private func beginLoop() {
        loop?.cancel()
        guard enabled else { status = "已暂停监测"; return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "watchEnabled")
        loop?.cancel(); reminder?.close(); reminder = nil
        candidates = []; announced = []; AppModel.shared.reconcileDeletedCandidates([])
        monitor = DeletionMonitor(roots: roots, ignoredBundleIDs: excludedIDs)
        beginLoop()
    }
    func updateRoots(_ roots: [URL]) {
        self.roots = roots
        AppModel.shared.reconcileDeletedCandidates([])
        Task { await monitor?.configure(roots: roots, ignoredBundleIDs: excludedIDs) }
    }
    func poll() async {
        guard enabled, let currentMonitor = monitor else { return }
        let report = await currentMonitor.poll()
        guard enabled, currentMonitor === monitor else { return }
        candidates = report.candidates; warnings = report.warnings
        status = report.isBaselineReady ? "正在监测 \(report.trackedApplicationCount) 个应用 · 每 2 秒检查" : "正在建立监测清单…"
        AppModel.shared.reconcileDeletedCandidates(candidates)
        announced.formIntersection(Set(candidates.map(\.id)))
        if let reminderID, !candidates.contains(where: { $0.id == reminderID }) { closeReminder() }
        guard !AppModel.shared.busy, !AppModel.shared.showConfirmation, reminder == nil,
              let candidate = candidates.first(where: { !announced.contains($0.id) }) else { return }
        announced.formUnion(candidates.map(\.id))
        showReminder(candidate)
    }
    func isValid(_ candidate: DeletedAppCandidate) async -> Bool {
        guard enabled, let monitor else { return false }
        let report = await monitor.poll()
        guard enabled, monitor === self.monitor, !excludedIDs.contains(candidate.app.bundleID) else { return false }
        return report.candidates.contains { $0.id == candidate.id }
    }
    func suppressRecycledApplications(at urls: [URL]) async {
        await monitor?.suppressRecycledApplications(at: urls)
    }
    func ignore(_ candidate: DeletedAppCandidate) {
        ignored[candidate.app.bundleID] = candidate.app.name
        saveIgnored(); closeReminder()
    }
    func removeIgnored(_ id: String) { ignored.removeValue(forKey: id); saveIgnored() }
    private func saveIgnored() {
        UserDefaults.standard.set(ignored, forKey: "ignoredApps")
        refreshProtection()
    }
    func refreshProtection() {
        candidates.removeAll { excludedIDs.contains($0.app.bundleID) }
        AppModel.shared.reconcileDeletedCandidates(candidates)
        if let reminderID, !candidates.contains(where: { $0.id == reminderID }) { closeReminder() }
        Task { await monitor?.configure(roots: roots, ignoredBundleIDs: excludedIDs); await poll() }
    }
    func dismiss(_ candidate: DeletedAppCandidate) {
        candidates.removeAll { $0.id == candidate.id }
        Task { await monitor?.dismiss(candidateID: candidate.id) }
    }
    func closeReminder() { reminder?.close(); reminder = nil; reminderID = nil }
    func view(_ candidate: DeletedAppCandidate) {
        closeReminder(); AppLifecycle.shared?.showMain()
        AppModel.shared.loadDeleted(candidate)
    }
    private func showReminder(_ candidate: DeletedAppCandidate) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 270), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "清舟 · 深度清理提醒"
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DeletionReminder(candidate: candidate, watch: self))
        panel.center(); panel.orderFrontRegardless(); reminder = panel; reminderID = candidate.id
    }
    func refreshLoginStatus() {
        let state = SMAppService.mainApp.status
        loginEnabled = state == .enabled || state == .requiresApproval
        switch state {
        case .enabled: loginStatus = "已开启：登录后自动打开清舟"
        case .requiresApproval: loginStatus = "已提交，需在系统登录项设置中允许"
        case .notRegistered: loginStatus = "未开启：重启电脑后需手动打开清舟"
        case .notFound: loginStatus = "尚未注册登录启动；可尝试开启，或在系统登录项中手动添加清舟"
        @unknown default: loginStatus = "无法读取登录启动状态"
        }
    }
    func setLogin(_ value: Bool) {
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { AppModel.shared.alert = "登录启动设置未完成：\(error.localizedDescription)" }
        refreshLoginStatus()
    }
}

struct DeletionReminder: View {
    let candidate: DeletedAppCandidate
    @ObservedObject var watch: CleanupWatch
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("发现应用已移入废纸篓", systemImage: "trash.circle.fill").font(.title2.bold()).foregroundStyle(teal)
            Text("“\(candidate.app.name)”可能还有缓存、设置或应用数据留在电脑上。").font(.body).fixedSize(horizontal: false, vertical: true)
            Text("查看关联文件后再决定是否清理。不会自动删除任何文件。").font(.caption).foregroundStyle(.secondary)
            if watch.candidates.count > 1 { Text("另外还有 \(watch.candidates.count - 1) 个应用待检查。").font(.caption).foregroundStyle(teal) }
            HStack {
                Button("忽略此应用") { watch.ignore(candidate) }.buttonStyle(.plain).font(.caption)
                Spacer()
                Button("稍后") { watch.closeReminder() }
                Button("查看关联文件") { watch.view(candidate) }.buttonStyle(.borderedProminent).tint(teal)
            }
        }.padding(25).frame(width: 470)
    }
}

struct WatchSettingsView: View {
    @ObservedObject var watch = CleanupWatch.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("拖入废纸篓后提醒深度清理", isOn: Binding(get: { watch.enabled }, set: watch.setEnabled))
            Text(watch.status).font(.caption).foregroundStyle(teal)
            Text("关闭主窗口后，菜单栏中的清舟仍会监测。选择“退出清舟”会停止监测；重新开启监测只关注之后的删除操作。").font(.caption).foregroundStyle(.secondary)
            Toggle("登录电脑时自动打开清舟", isOn: Binding(get: { watch.loginEnabled }, set: watch.setLogin))
            Text(watch.loginStatus).font(.caption).foregroundStyle(.secondary)
            Button("打开系统登录项设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
            if !watch.warnings.isEmpty {
                Text(watch.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                Button("打开完全磁盘访问设置") { AppModel.shared.openPrivacy() }
            }
            if !watch.ignored.isEmpty {
                Divider(); Text("不再提醒的应用").font(.headline)
                ForEach(watch.ignored.keys.sorted(), id: \.self) { id in
                    HStack { Text(watch.ignored[id] ?? id).font(.caption); Spacer(); Button("恢复提醒") { watch.removeIgnored(id) } }
                }
            }
        }.onAppear { watch.refreshLoginStatus() }
    }
}
