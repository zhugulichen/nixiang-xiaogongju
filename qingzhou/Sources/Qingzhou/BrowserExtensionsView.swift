import SwiftUI
import AppKit
import CleanCore

@MainActor private final class ExtensionLibrary: ObservableObject {
    @Published var report: BrowserExtensionReport?
    @Published var status = "准备读取浏览器扩展"
    @Published var reading = false
    private var job: Task<Void, Never>?
    func read() {
        cancel()
        status = "正在读取扩展清单…"; reading = true
        job = Task { [weak self] in
            let reader = Task.detached(priority: .utility) { try BrowserExtensionService().scan() }
            do {
                let report = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
                try Task.checkCancellation()
                self?.report = report
                self?.status = "已读取 \(report.profiles) 个配置 · 共 \(report.records.count) 个扩展"
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = "读取未完成：\(error.localizedDescription)"
            }
            self?.reading = false
        }
    }
    func cancel() {
        job?.cancel(); job = nil
        if reading { status = "已取消读取"; reading = false }
    }
    deinit { job?.cancel() }
}

struct BrowserExtensionsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @StateObject private var library = ExtensionLibrary()
    @ViewState private var search = ""
    @ViewState private var browser: ExtensionBrowser?
    @ViewState private var selectedID: String?
    @ViewState private var browserMessage = ""
    @ViewState private var showWarnings = false
    @ViewState private var pending: BrowserExtensionRecord?
    @ViewState private var removing = false
    @ViewState private var lastRequest: BrowserExtensionRecord?
    @ViewState private var recycledPackage: URL?
    @ViewState private var removalMessage = ""

    private var records: [BrowserExtensionRecord] {
        (library.report?.records ?? []).filter { row in
            (browser == nil || browser == row.browser) && (search.isEmpty ||
                [row.name, row.profile, row.identifier].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("浏览器扩展").font(.title2.bold())
                    Text(library.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if library.reading { ProgressView().controlSize(.small); Button("取消读取") { library.cancel() } }
                else { Button("刷新清单") { library.read() }.disabled(removing) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(removing)
            }
            HStack {
                TextField("搜索扩展、配置或标识", text: $search).textFieldStyle(.roundedBorder)
                Picker("浏览器", selection: $browser) {
                    Text("全部浏览器").tag(nil as ExtensionBrowser?)
                    ForEach(ExtensionBrowser.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(width: 205)
            }
            if !removalMessage.isEmpty {
                HStack {
                    Text(removalMessage).font(.caption).textSelection(.enabled)
                    Spacer()
                    if let lastRequest {
                        Button("核对移除结果") { checkRegistration(lastRequest) }.disabled(removing)
                    }
                    if let recycledPackage {
                        Button("在废纸篓中显示") { NSWorkspace.shared.activateFileViewerSelecting([recycledPackage]) }
                    }
                }
            }
            if let warnings = library.report?.warnings, !warnings.isEmpty {
                Button("部分记录未能完整读取（\(warnings.count) 条提示）") { showWarnings = true }
                    .font(.caption).foregroundStyle(.orange)
                    .popover(isPresented: $showWarnings) {
                        ScrollView { Text(warnings.joined(separator: "\n\n")).font(.caption).textSelection(.enabled).padding(16) }
                            .frame(width: 440, height: 210)
                    }
            }
            Divider()
            if let report = library.report, report.records.isEmpty {
                Text(report.warnings.isEmpty ? "在支持的标准配置目录中未发现扩展记录。" : "未读到扩展记录，请查看上方的读取提示。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                Text(library.reading ? "正在检查本机配置…" : (library.report == nil ? library.status : "没有符合筛选条件的扩展。"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(records) { row in
                                Button { selectedID = row.id } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.name).lineLimit(2)
                                        Text("\(row.browser.rawValue) · \(row.profile)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(selectedID == row.id ? teal.opacity(0.1) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(4)
                    }
                    .frame(width: 225)
                    .frame(maxHeight: .infinity)
                    Divider()
                    if let row = records.first(where: { $0.id == selectedID }) ?? records.first {
                        details(row).id(row.id)
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.padding(22).frame(width: 810, height: 555)
        .interactiveDismissDisabled(removing)
        .alert("移除浏览器扩展", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { row in
            Button("取消", role: .cancel) {}
            Button(row.browser == .firefox ? "将扩展包移入废纸篓" : "发起浏览器移除", role: .destructive) { requestRemoval(row) }
        } message: { row in
            Text("浏览器：\(row.browser.rawValue)\n配置：\(row.profile)\n扩展：\(row.name) · \(row.identifier)\n" +
                 (row.browser == .firefox ? "请完整退出火狐。扩展包可从废纸篓放回原处，重新启动火狐后可以核对移除结果。" : "将在此配置中定位该扩展，由浏览器处理移除和同步；请核对浏览器的最终确认。"))
        }
        .onAppear { library.read() }.onDisappear { library.cancel() }
        .onChange(of: selectedID) { _, _ in browserMessage = "" }
        .onChange(of: records.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
    }

    private func details(_ row: BrowserExtensionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.name).font(.title3.bold()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(row.browser.rawValue) · \(row.profile) · 版本 \(row.version)").font(.callout)
                Text(row.identifier).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(row.state) · \(row.source)").font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.note.isEmpty {
                    Text(row.note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("权限声明").font(.headline)
                Text("以下内容取自扩展清单或浏览器保存的声明。实际授权和启停状态以对应浏览器为准。").font(.caption).foregroundStyle(.secondary)
                if [row.permissions, row.sites, row.optionalPermissions, row.optionalSites, row.scriptSites].allSatisfy(\.isEmpty) {
                    Text("未读到权限声明。").font(.callout)
                }
                group("所需权限", row.permissions); group("网站范围", row.sites)
                group("可选权限", row.optionalPermissions); group("可选网站范围", row.optionalSites)
                group("内容脚本匹配范围", row.scriptSites)
                Divider()
                if row.removal != .unavailable {
                    Button("移除这个扩展…", role: .destructive) { pending = row }
                        .disabled(removing || library.reading || model.modifyingFiles || model.protectionError != nil || model.skippedRelatedIDs.contains(row.browser.bundleID))
                } else {
                    Text("此项的来源、文件或管理策略不支持清舟直接移除。").font(.caption)
                }
                if row.removal == .browserConfirmation, !BrowserRemovalAction.hasAccessibilityAccess {
                    HStack {
                        Text("允许清舟使用辅助功能后，可直接发起浏览器的移除确认。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("打开辅助功能设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Text("在\(row.browser.rawValue)切换至“\(row.profile)”配置可查看管理详情。").font(.caption)
                Text(row.detailAddress).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("前往浏览器管理页") { openManager(row) }
                    Button("复制地址") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.detailAddress, forType: .string)
                        browserMessage = "已复制管理页地址。"
                    }
                }
                if !browserMessage.isEmpty { Text(browserMessage).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            DisclosureGroup("\(title)（\(items.count)）") {
                Text(items.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.callout)
        }
    }
    private func requestRemoval(_ row: BrowserExtensionRecord) {
        guard !removing, !model.modifyingFiles,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.browser.bundleID) else {
            removalMessage = "浏览器不可用或另一个操作正在进行。"; return
        }
        removing = true; removalMessage = "正在核对所选扩展…"; lastRequest = nil; recycledPackage = nil
        let policy = model.protectionPolicy
        Task {
            defer { removing = false }
            do {
                let service = BrowserExtensionService()
                let file = CleanFile(url: service.targetURL(for: row), kind: .extensionFile, reason: "浏览器扩展", ownerBundleID: row.browser.bundleID)
                try policy.validate(file)
                if row.browser == .firefox {
                    let moved = try await Task.detached {
                        try service.recycleFirefoxPackage(row, firefoxApp: app, browserRunning: {
                            !NSRunningApplication.runningApplications(withBundleIdentifier: row.browser.bundleID).isEmpty
                        })
                    }.value
                    recycledPackage = moved
                    removalMessage = "扩展包已移入废纸篓。请重新启动火狐，再核对配置登记。"
                } else {
                    try await Task.detached { try service.validateRemoval(row) }.value
                    try model.protectionPolicy.validate(file)
                    let pressed = try await BrowserRemovalAction.openConfirmation(row, application: app)
                    removalMessage = pressed ? "已发起浏览器原生移除，请在浏览器确认后核对结果。" :
                        "已请求打开所选配置的扩展详情。请在浏览器核对名称并点击移除，然后在此核对结果。"
                }
                lastRequest = row; library.read()
            } catch { removalMessage = "移除未完成：\(error.localizedDescription)" }
        }
    }

    private func checkRegistration(_ row: BrowserExtensionRecord) {
        guard !removing else { return }; removing = true
        Task {
            defer { removing = false }
            let result = try? await Task.detached { try BrowserExtensionService().isRegistered(row) }.value
            switch result {
            case false: removalMessage = "已核对“\(row.profile)”配置，浏览器已移除“\(row.name)”的登记。"; lastRequest = nil
            case true: removalMessage = "“\(row.name)”仍在此配置的登记中。请确认浏览器已完成移除并保存配置。"
            case nil: removalMessage = "无法完整读取所选配置，当前未能确认移除结果。"
            }
            library.read()
        }
    }

    private func openManager(_ row: BrowserExtensionRecord) {
        let browser = row.browser
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
              let address = URL(string: row.detailAddress) else {
            browserMessage = "系统未找到对应浏览器。"; return
        }
        browserMessage = "若浏览器未打开管理页，可复制上方地址并粘贴到其地址栏。"
        NSWorkspace.shared.open([address], withApplicationAt: appURL, configuration: .init()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                browserMessage = "浏览器未接受管理页链接，可打开浏览器并粘贴上方地址。"
            }
        }
    }
}
