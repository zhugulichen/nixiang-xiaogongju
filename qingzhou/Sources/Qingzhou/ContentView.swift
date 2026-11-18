import SwiftUI
import AppKit
import CleanCore

let teal = Color(red: 0.08, green: 0.49, blue: 0.45)

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var applicationDetails: ApplicationDetails?
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                switch model.page {
                case .smartCleanup: SmartCleanupView()
                case .applications: applications
                case .batchUninstall: BatchUninstallView()
                case .network: NetworkTrafficView()
                case .leftovers, .caches, .extensions, .installers: standaloneFiles
                case .startup: StartupView()
                case .updates: UpdatesView(center: model.updates)
                case .defaults: DefaultsView()
                case .history: HistoryView()
                case .privacy: PrivacyView()
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(teal)
        .dropDestination(for: URL.self) { urls, _ in model.openApplications(urls) } isTargeted: { model.dropTargeted = $0 }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 14).stroke(teal, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(5).allowsHitTesting(false)
            }
        }
        .alert("清舟", isPresented: Binding(get: { model.alert != nil && !model.showScanRoots }, set: { if !$0 && !model.showScanRoots { model.alert = nil } })) {
            if let entry = model.failedEntry, let app = model.finderRetryTarget(for: entry) {
                Button("通过访达回收") { model.alert = nil; model.reviewFinderRecovery(app, previous: entry) }
            }
            if !model.bodiesForSeparateReview.isEmpty {
                let bodies = model.bodiesForSeparateReview
                Button("保留数据，仅检查应用本体") { model.alert = nil; model.prepareBodiesOnly(bodies) }
            }
            if model.cleanupFailure?.category == .applicationManagement {
                Button("打开应用管理设置") { model.alert = nil; model.openAppManagement() }
            } else if model.cleanupFailure?.category == .automation {
                Button("查看访达控制授权") { model.alert = nil; model.openAutomationPrivacy() }
            } else if model.cleanupFailure?.category == .appData {
                Button("查看数据访问设置") { model.alert = nil; model.openPrivacy() }
            }
            if model.offerCleanupHistory {
                Button("查看清理记录") { model.alert = nil; model.changePage(.history) }
            }
            Button("知道了", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .sheet(isPresented: $model.showConfirmation) { ReviewSheet() }
        .sheet(isPresented: $model.showScanRoots) { ScanRootsSheet() }
        .onChange(of: model.usageFilterMode) { _, _ in model.reconcileApplicationSelection() }
        .onChange(of: model.idleDays) { _, _ in model.reconcileApplicationSelection() }
        .onChange(of: model.search) { _, _ in model.reconcileApplicationSelection() }
        .sheet(item: $applicationDetails) { details in
            switch details {
            case .details(let app): AppDetailsView(app: app)
            case .overview: CompatibilityOverview(apps: model.apps)
            case .browser: BrowserExtensionsView()
            case .assessment(let app): AppAssessmentView(app: app)
            case .permissions(let app): AppPermissionsView(app: app)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sailboat.fill").font(.system(size: 29)).foregroundStyle(teal)
                    .frame(width: 46, height: 46).background(teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("清舟").font(.system(size: 26, weight: .bold))
                    Text("轻一点，从容一点").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 43).padding(.bottom, 30)
            Text("应用与空间").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) { ForEach(Page.allCases.filter { $0 != .history && $0 != .privacy }) { item in navRow(item) } }
            }.scrollIndicators(.hidden)
            Spacer(minLength: 8)
            ForEach(Page.allCases.suffix(2)) { item in navRow(item) }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) { Circle().fill(teal).frame(width: 6, height: 6); Text("在本机分析").font(.system(size: 11, weight: .medium)) }
                Text("不上传文件内容\n每次清理，先由你确认").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 13)).padding(16)
        }
        .frame(width: 208)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func navRow(_ item: Page) -> some View {
        Button { model.changePage(item) } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 20)
                Text(item.rawValue).font(.system(size: 13, weight: model.page == item ? .semibold : .regular))
                Spacer()
                if item == .applications && !model.apps.isEmpty { Text("\(model.apps.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .foregroundStyle(model.page == item ? teal : Color.primary.opacity(0.78))
            .background(model.page == item ? teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.horizontal, 11).padding(.vertical, 2).disabled(model.modifyingFiles)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.page.rawValue).font(.system(size: 27, weight: .bold))
                Text(model.page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                if [.applications, .leftovers, .caches, .extensions, .smartCleanup, .batchUninstall].contains(model.page) { Text(model.sizeStatus).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small); Text(model.activity).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 170) }
            if !model.files.isEmpty {
                Button(model.sizing ? "取消统计" : "完整统计") { if model.sizing { model.cancelMeasurement() } else { model.measureFiles() } }.disabled(model.busy || model.fileBusy)
            }
            Button { model.scan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }.disabled(model.busy).controlSize(.large)
        }.padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 24)
    }

    private var applications: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                HStack {
                    Text("\(model.shownApps.count) 个应用").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("排序", selection: $model.applicationSort) {
                        ForEach(ApplicationSortOrder.allCases, id: \.self) { order in Text(order.rawValue).tag(order) }
                    }.labelsHidden().frame(width: 115)
                }.padding(.horizontal, 17).padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 8) {
                    Picker("使用情况", selection: $model.usageFilterMode) {
                        Text("全部应用").tag("全部应用")
                        Text("闲置应用").tag("闲置应用")
                        Text("使用时间未知").tag("使用时间未知")
                    }.labelsHidden()
                    if model.usageFilterMode == "闲置应用" {
                        Stepper("至少 \(model.idleDays) 天未使用", value: $model.idleDays, in: 1...3650)
                            .font(.caption)
                    }
                    HStack {
                        Text(model.usageLoading ? "正在读取系统使用记录…" : "系统记录：\(model.lastUsedDates.count)/\(model.apps.count) 个应用")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.refreshUsage() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).help("刷新使用记录").disabled(model.busy || model.usageLoading)
                    }
                    if model.usageFilterMode != "全部应用" {
                        Text("使用时间可能缺失，未知不会视为闲置。").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 17).padding(.bottom, 12).disabled(model.modifyingFiles)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.shownApps) { app in
                            Button { model.selectApp(app) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    AppRow(app: app, selected: model.selectedAppID == app.id, skipped: model.isSkipped(app))
                                    if model.applicationSort == .lastUsed || model.usageFilterMode != "全部应用" {
                                        Text(model.lastUsedDates[app.id].map { "最近使用：" + $0.formatted(date: .abbreviated, time: .omitted) } ?? "最近使用时间未知")
                                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 51).padding(.bottom, 8)
                                    }
                                }
                            }.buttonStyle(.plain).disabled(model.modifyingFiles)
                        }
                    }.padding(.horizontal, 9).padding(.bottom, 12)
                }
                Divider()
                VStack(spacing: 10) {
                    Button("查看应用兼容性") { applicationDetails = .overview }.disabled(model.busy || model.modifyingFiles)
                    Text("也可将应用拖到这个窗口查看").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button { model.showScanRoots = true } label: { Label("管理扫描文件夹", systemImage: "folder.badge.gearshape").frame(maxWidth: .infinity) }
                        .buttonStyle(.plain).font(.caption).disabled(model.busy || model.modifyingFiles)
                }.padding(15)
            }.frame(width: 292).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            VStack(spacing: 0) {
                if let app = model.selectedApp {
                    HStack(spacing: 15) {
                        AppIcon(url: app.url, size: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.name).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                            Text("版本 \(app.version) · \(DisplayFormat.bytes(app.bytes))").font(.caption).foregroundStyle(.secondary)
                            Text(app.bundleID).font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1)
                        }
                        Spacer()
                        Menu {
                            Button("应用详情") { applicationDetails = .details(app) }
                            Button("签名检查") { applicationDetails = .assessment(app) }
                            Button("隐私权限") { applicationDetails = .permissions(app) }
                            if !app.isProtected {
                                Divider()
                                if let record = model.skippedApplications.first(where: { $0.relatedIdentifiers.contains(app.bundleID) || $0.bundleID == app.bundleID }) {
                                    Button("从跳过名单移除") { model.removeSkippedApplication(record.bundleID) }.disabled(model.busy || model.protectionError != nil)
                                } else {
                                    Button("加入全局跳过名单") { model.skipApplication(app) }.disabled(model.busy || model.protectionError != nil)
                                }
                            }
                            if !app.isProtected && !model.selectedAppOutsideScanRoots {
                                Divider()
                                Button("通过访达回收…", role: .destructive) { model.reviewFinderRecovery(app) }
                                    .disabled(model.busy || model.fileBusy || model.isSkipped(app))
                            }
                        } label: { Label("应用信息", systemImage: "info.circle") }.fixedSize().disabled(model.modifyingFiles)
                        Button { model.reveal(app.url) } label: { Image(systemName: "folder") }.help("在访达中显示")
                    }.padding(24)
                    if model.isSkipped(app) {
                        Notice(text: "已加入全局跳过名单：应用本体及已核对的关联数据受到保护。可在应用信息菜单或“权限与说明”中移除保护。", symbol: "hand.raised.fill")
                    }
                    if app.isProtected {
                        Notice(text: "此应用受保护，仅供查看。系统应用和清舟自身不能清理。", symbol: "lock.fill")
                    } else {
                        if model.selectedAppOutsideScanRoots {
                            Notice(text: "临时查看：此应用位于扫描范围之外，本体不可勾选。需要卸载本体时，请在“管理扫描文件夹”中添加它所在的专用应用目录。", symbol: "folder.badge.questionmark")
                        }
                        Picker("清理方式", selection: $model.scope) {
                            Text("卸载应用").tag("卸载应用")
                            Text("仅清缓存").tag("仅清缓存")
                            Text("重置设置").tag("重置设置")
                        }.pickerStyle(.segmented).padding(.horizontal, 24).disabled(model.modifyingFiles).onChange(of: model.scope) { _, _ in model.applyScope() }
                        Text(model.scope == "重置设置" ? "重置会清除设置与登录状态；应用本体和未勾选的数据会保留。" : "应用数据可能包含账号、聊天记录或项目，请逐项核对。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 13)
                    }
                    Divider()
                    FileListView(useSearch: false)
                    cleanFooter
                } else {
                    EmptyViewCard(symbol: "square.grid.2x2", title: model.busy ? "正在发现你的应用" : "选择一个应用", subtitle: model.busy ? "首次扫描需要一点时间，期间不会修改任何文件。" : "从左侧选择应用，或将应用拖入窗口，查看空间占用和关联文件。")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var standaloneFiles: some View {
        VStack(spacing: 0) {
            HStack {
                searchField.frame(maxWidth: 400)
                Spacer()
                Text("\(model.files.count) 项 · \(DisplayFormat.bytes(model.files.reduce(0) { $0 + $1.bytes }))").font(.caption).foregroundStyle(.secondary).padding(.trailing, 24)
            }
            if model.page == .leftovers {
                Notice(text: "可能属于其他用户、移动到别处的应用或后台组件。没有归属证明的项目不会自动选择。", symbol: "info.circle")
            } else if model.page == .installers {
                Notice(text: "按大小列出下载目录里的安装文件。磁盘映像可能装有个人文件，请核对后勾选。已挂载的映像需先弹出。", symbol: "shippingbox")
                if !model.installerWarnings.isEmpty {
                    DisclosureGroup("部分下载目录未能读取") {
                        ScrollView { Text(model.installerWarnings.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 90)
                    }.padding(.horizontal, 24)
                }
            } else if model.page == .extensions {
                Notice(text: "查看传统插件和用户服务。可进入“浏览器扩展”选择要移除的项目，系统扩展由系统设置管理。", symbol: "puzzlepiece.extension")
                HStack {
                    Button("查看浏览器扩展") { applicationDetails = .browser }.buttonStyle(.borderedProminent)
                    Button("打开扩展设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                    Spacer()
                }.padding(.horizontal, 24).padding(.bottom, 12)
            } else {
                Notice(text: "建议先退出对应应用。清理缓存后，应用可能需要重新下载内容。", symbol: "info.circle")
            }
            FileListView(useSearch: true)
            cleanFooter
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称或路径", text: $model.search).textFieldStyle(.plain)
            if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
        }.font(.system(size: 12)).padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)).padding(15)
    }

    private var cleanFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选择 \(model.selectedFiles.count) 项").font(.system(size: 12, weight: .medium))
                    Text(DisplayFormat.bytes(model.selectedBytes)).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(teal)
                }
                Spacer()
                Button("取消选择") { model.selectedFiles = [] }.disabled(model.selectedFiles.isEmpty).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Button { model.reviewSelection() } label: { Label("检查并清理", systemImage: "trash").padding(.horizontal, 8).padding(.vertical, 5) }.buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.busy || model.fileBusy)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }
}

private enum ApplicationDetails: Identifiable {
    case details(AppRecord), assessment(AppRecord), permissions(AppRecord), overview, browser
    var id: String {
        switch self {
        case .details(let app): return "details:" + app.id
        case .overview: return "overview"
        case .browser: return "browser"
        case .assessment(let app): return "assessment:" + app.id
        case .permissions(let app): return "permissions:" + app.id
        }
    }
}

struct AppIcon: View {
    let url: URL
    var size: CGFloat = 36
    var body: some View { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).frame(width: size, height: size) }
}

struct AppRow: View {
    let app: AppRecord
    let selected: Bool
    var skipped = false
    var body: some View {
        HStack(spacing: 11) {
            AppIcon(url: app.url)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(DisplayFormat.bytes(app.bytes)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 1)
            if app.isProtected || skipped { Image(systemName: skipped ? "hand.raised.fill" : "lock.fill").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 10).padding(.vertical, 10).background(selected ? teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
    }
}

struct FileListView: View {
    @EnvironmentObject var model: AppModel
    let useSearch: Bool
    @ViewState private var showDirectories = false
    @ViewState private var showComponents = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.fileBusy {
                HStack {
                    if !model.directoryStatuses.isEmpty {
                        let incomplete = model.directoryStatuses.filter(\.incomplete).count
                        Button(incomplete == 0 ? "查看扫描位置" : "扫描位置 · \(incomplete) 处读取受限") { showDirectories = true }
                            .foregroundStyle(incomplete > 0 ? Color.orange : teal)
                    }
                    if [.applications, .leftovers, .smartCleanup].contains(model.page) {
                        Button("检查安装收据与后台组件") { showComponents = true }
                    }
                    Spacer()
                }.font(.caption).padding(.horizontal, 23).padding(.vertical, 5)
            }
            if model.fileBusy {
                VStack(spacing: 14) { ProgressView(); Text("正在核对文件归属与大小…").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if (useSearch ? model.shownFiles : model.files).isEmpty {
                EmptyViewCard(symbol: "checkmark.circle", title: model.directoryStatuses.contains(where: \.incomplete) ? "已读取的位置中没有匹配项目" : "没有发现匹配项目", subtitle: model.directoryStatuses.isEmpty ? "可以更改筛选条件或重新扫描。" : "可在扫描位置中核对各目录的读取结果。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(useSearch ? model.shownFiles : model.files) { file in
                            HStack(alignment: .top, spacing: 11) {
                                Toggle("选择 \(file.url.lastPathComponent)", isOn: Binding(get: { model.selectedFiles.contains(file.id) }, set: { value in if value { model.selectedFiles.insert(file.id) } else { model.selectedFiles.remove(file.id) } }))
                                    .labelsHidden().toggleStyle(.checkbox).disabled(file.risk == .protected || model.busy).padding(.top, 3)
                                Image(systemName: file.kind == .application ? "app.fill" : "doc.text").foregroundStyle(teal.opacity(0.8)).frame(width: 18).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(file.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        if file.risk == .personal { Text("个人数据").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange).padding(.horizontal, 5).padding(.vertical, 2).background(.orange.opacity(0.08), in: Capsule()) }
                                    }
                                    Text(file.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                    Text("\(file.kind.rawValue) · \(file.reason)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                                }
                                Spacer(minLength: 5)
                                VStack(alignment: .trailing, spacing: 9) {
                                    Text(DisplayFormat.bytes(file.bytes)).font(.system(size: 11, weight: .medium, design: .rounded))
                                    Button { model.reveal(file.url) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("在访达中显示")
                                }
                            }.padding(.vertical, 14).padding(.horizontal, 23)
                            Divider().padding(.leading, 53)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showDirectories) { DirectoryScanView(directories: model.directoryStatuses) }
        .sheet(isPresented: $showComponents) {
            let deleted = model.page == .smartCleanup ? model.deletedContext : nil
            let target = deleted.map { AppRecord(url: $0.trashURL, name: $0.app.name, bundleID: $0.app.bundleID, version: $0.app.version) }
            InstallationAuditView(app: model.page == .applications ? model.selectedApp : target, original: deleted?.app.url)
        }
    }
}

struct Notice: View {
    let text: String
    var symbol = "info.circle"
    var body: some View { HStack(alignment: .top, spacing: 9) { Image(systemName: symbol).foregroundStyle(teal); Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3); Spacer(minLength: 0) }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 24).padding(.bottom, 14) }
}

struct EmptyViewCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 42, weight: .ultraLight)).foregroundStyle(teal.opacity(0.6))
            Text(title).font(.system(size: 18, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360).lineSpacing(5)
        }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("确认移入废纸篓", systemImage: "trash.circle.fill").font(.system(size: 23, weight: .semibold)).foregroundStyle(teal)
            Text("共 \(model.pendingFiles.count) 项，约 \(DisplayFormat.bytes(model.pendingFiles.reduce(0) { $0 + $1.bytes }))。\n请检查下面的完整路径；清理后可在“清理记录”中尝试恢复。").font(.system(size: 13)).lineSpacing(5)
            if let description = model.pendingCleanupDescription { Text(description).font(.caption).foregroundStyle(teal) }
            if model.pendingTrashMethod != .finderInteractive && model.pendingFiles.contains(where: { $0.kind == .application }) {
                Toggle("应用本体因权限被拒时，通过访达重试", isOn: Binding(
                    get: { model.pendingTrashMethod == .systemWithFinderFallback },
                    set: { model.pendingTrashMethod = $0 ? .systemWithFinderFallback : .systemInteractive }
                )).toggleStyle(.checkbox)
                if model.pendingTrashMethod == .systemWithFinderFallback {
                    Text("仅对本次勾选的应用生效。系统可能要求允许清舟控制访达或验证身份。本体成功回收后，清舟才继续处理勾选的关联数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.pendingFiles.contains(where: { $0.risk == .personal || $0.kind == .preference }) {
                Label("选中项包含应用数据或设置，可能影响登录状态、历史记录和个人配置。", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.pendingFiles) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.url.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            Text("\(file.kind.rawValue) · \(DisplayFormat.bytes(file.bytes))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(height: 260).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("系统可能请你确认移除或验证身份").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("返回检查") { model.showConfirmation = false }.keyboardShortcut(.cancelAction)
                Button(model.pendingTrashMethod == .finderInteractive ? "通过访达移入废纸篓" : "移入废纸篓", role: .destructive) { model.confirmTrash() }.buttonStyle(.borderedProminent).tint(.red)
            }
        }.padding(28).frame(width: 620)
    }
}
