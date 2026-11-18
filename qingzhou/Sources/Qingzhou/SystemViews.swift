import SwiftUI
import AppKit
import CleanCore

// Select the property wrapper explicitly; command-line tools omit the newer State macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

struct StartupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var watch = CleanupWatch.shared
    @ViewState private var pending: StartupEntry?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Toggle("登录电脑时自动打开清舟", isOn: Binding(get: { watch.loginEnabled }, set: watch.setLogin))
                    .fixedSize().disabled(model.modifyingFiles)
                Text(watch.loginStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 24).padding(.top, 20)
            HStack {
                Notice(text: "仅支持切换当前用户的独立启动代理。登录项目和系统后台服务请通过系统设置管理。", symbol: "power")
                Button("打开登录项设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }.padding(.trailing, 24)
            }.padding(.top, 20)
            if model.fileBusy { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.startupItems) { entry in
                            HStack(alignment: .center, spacing: 15) {
                                Image(systemName: entry.canToggle ? "person.crop.circle.badge.checkmark" : "gearshape.2").font(.system(size: 23)).foregroundStyle(teal).frame(width: 36)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.name).font(.system(size: 13, weight: .semibold))
                                    Text(entry.label).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(entry.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(entry.isEnabled ? "已启用" : "已停用").font(.caption).foregroundStyle(entry.isEnabled ? teal : .secondary)
                                Button { model.reveal(entry.url) } label: { Image(systemName: "folder") }.help("查看配置")
                                if entry.canToggle { Button(entry.isEnabled ? "停用" : "启用") { pending = entry }.disabled(model.busy) }
                                else { Text("系统管理").font(.caption).foregroundStyle(.tertiary).frame(width: 60) }
                            }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(24)
                }
            }
        }
        .alert("修改启动项目", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("取消", role: .cancel) { pending = nil }
            Button("确认修改") { if let pending { model.toggleStartup(pending) }; pending = nil }
        } message: {
            Text(pending.map { "\($0.isEnabled ? "停用会停止" : "启用会启动")“\($0.name)”的后台代理，并改变后续自动启动行为。\n\($0.url.path)" } ?? "")
        }
    }
}

struct DefaultsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var ext = "pdf"
    @ViewState private var loadedExtension = "pdf"
    @ViewState private var current: URL?
    @ViewState private var choices: [URL] = []
    @ViewState private var chosen: URL?
    @ViewState private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 12) {
                Text("文件扩展名").font(.headline)
                TextField("例如 pdf、jpg、txt", text: $ext).textFieldStyle(.roundedBorder).frame(width: 180).onSubmit { load() }.disabled(working)
                Button("查找") { load() }.disabled(working)
                Spacer()
            }
            HStack(spacing: 9) {
                    ForEach(["pdf", "txt", "jpg", "png", "mp4", "html"], id: \.self) { value in Button(value) { ext = value; load() }.buttonStyle(.bordered).disabled(working) }
            }
            Divider()
            if let current {
                HStack(spacing: 16) {
                    AppIcon(url: current, size: 56)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("当前默认应用").font(.caption).foregroundStyle(.secondary)
                        Text(current.deletingPathExtension().lastPathComponent).font(.title2.bold())
                        Text(current.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else { Text("系统未设置此类型的默认应用。").foregroundStyle(.secondary) }
            Text("可用于打开此类型的应用").font(.headline).padding(.top, 10)
            ScrollView {
                VStack(spacing: 9) {
                    ForEach(choices, id: \.path) { url in
                        HStack(spacing: 12) {
                            AppIcon(url: url)
                            Text(url.deletingPathExtension().lastPathComponent)
                            Spacer()
                            if url == current { Label("当前默认", systemImage: "checkmark.circle.fill").foregroundStyle(teal).font(.caption) }
                            else { Button("设为默认") { chosen = url }.disabled(working || ext != loadedExtension) }
                        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.padding(28).onAppear { load() }
        .alert("更改默认打开方式", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
            Button("取消", role: .cancel) { chosen = nil }
            Button("确认设置") {
                guard let app = chosen else { return }; let targetExtension = loadedExtension; chosen = nil; working = true
                Task {
                    do { try await DefaultAppService.setDefaultApplication(app, forExtension: targetExtension); load() }
                    catch { model.alert = error.localizedDescription }
                    working = false
                }
            }
        } message: { Text("将使用“\(chosen?.deletingPathExtension().lastPathComponent ?? "")”打开 .\(loadedExtension) 类型文件。系统可能会再次要求确认。") }
    }
    private func load() {
        do { current = try DefaultAppService.defaultApplication(forExtension: ext); choices = try DefaultAppService.applications(forExtension: ext); loadedExtension = ext }
        catch { model.alert = error.localizedDescription; current = nil; choices = [] }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var pending: (batch: TrashBatch, entry: TrashEntry?)?
    var body: some View {
        Group {
            if model.batches.isEmpty {
                EmptyViewCard(symbol: "clock.arrow.circlepath", title: "每次清理，都有来路", subtitle: "你的清理记录会出现在这里。文件保留在系统废纸篓中时，可以尝试恢复。")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.batches) { batch in
                            VStack(alignment: .leading, spacing: 13) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(batch.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                                        Text("\(batch.entries.count) 个项目 · \(batch.entries.filter(\.restored).count) 项已恢复").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("恢复这一批") { pending = (batch, nil) }.disabled(model.busy || batch.entries.allSatisfy { $0.restored || $0.trashURL == nil })
                                }
                                Divider()
                                ForEach(batch.entries) { entry in
                                    HStack(alignment: .top) {
                                        Image(systemName: entry.restored ? "checkmark.circle.fill" : "doc").foregroundStyle(entry.restored ? teal : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.originalURL.path).font(.caption).textSelection(.enabled)
                                            if entry.recycledByFinder == true, entry.error == nil {
                                                Text("本体由访达回收").font(.caption2).foregroundStyle(.secondary)
                                            }
                                            if let error = entry.error {
                                                Text(error).font(.caption2).foregroundStyle(.orange)
                                                if entry.trashURL == nil, !entry.restored {
                                                    HStack {
                                                        if let app = model.failedApplication(for: entry) {
                                                            Button("重新检查应用") { model.reopenFailedApplication(app) }.disabled(model.busy)
                                                        }
                                                        if let app = model.finderRetryTarget(for: entry) {
                                                            Button("通过访达回收") { model.reviewFinderRecovery(app, previous: entry) }.disabled(model.busy)
                                                        }
                                                        switch entry.failure?.category {
                                                        case .automation: Button("查看访达控制授权") { model.openAutomationPrivacy() }
                                                        case .applicationManagement: Button("检查应用管理授权") { model.openAppManagement() }
                                                        case .appData: Button("检查数据访问授权") { model.openPrivacy() }
                                                        default: EmptyView()
                                                        }
                                                        Button("查看原位置") { model.reveal(entry.originalURL) }
                                                    }.font(.caption)
                                                }
                                            }
                                        }
                                        Spacer()
                                        if !entry.restored, entry.trashURL != nil {
                                            Button("仅恢复此项") { pending = (batch, entry) }.disabled(model.busy)
                                        }
                                    }
                                }
                            }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                        }
                    }.padding(24)
                }
            }
        }.alert("恢复到原位置", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("取消", role: .cancel) { pending = nil }
            Button("恢复") { if let pending { model.restore(pending.batch, entryID: pending.entry?.id) }; pending = nil }
        } message: {
            if let entry = pending?.entry { Text("仅恢复到原位置：\n" + entry.originalURL.path + "\n已有同名文件时会跳过。") }
            else { Text("将这批仍在废纸篓中的文件移回原目录。已有同名文件时会跳过。") }
        }
    }
}

struct PrivacyView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ApplicationPreferencesView()
                infoCard("卸载与数据访问授权", symbol: "app.badge.checkmark", text: "卸载应用时系统可能要求应用管理授权或验证身份。读取其他应用的数据容器可能触发单独询问。如果系统拒绝，清理记录会保留失败路径和原因，可在授权后重新检查。") {
                    HStack {
                        Button("打开应用管理设置") { model.openAppManagement() }
                        Button("在访达中显示清舟") { model.reveal(Bundle.main.bundleURL) }
                    }
                }
                infoCard("普通回收被拒绝时", symbol: "folder.badge.gearshape", text: "可在卸载确认页勾选本次允许访达重试。访达只接收应用本体，清舟在本体回收成功后继续处理已勾选的数据。应用信息菜单也可单独回收本体。首次使用需要允许清舟控制访达，系统也可能要求验证身份；不愿授权时，可在访达手动移到废纸篓。") {
                    Button("查看访达控制授权") { model.openAutomationPrivacy() }
                }
                infoCard("扫描权限", symbol: "lock.shield", text: "系统可能限制访问应用容器、浏览器数据等目录。若需要更完整的扫描，可在系统设置中手动为清舟开启“完全磁盘访问权限”，随后退出并重新打开清舟。权限不足时，扫描结果可能不完整。") {
                    Button("打开完全磁盘访问设置") { model.openPrivacy() }
                }
                infoCard("已实现的功能", symbol: "checkmark.seal", text: "废纸篓自动清理提醒、菜单栏后台监测、忽略名单、登录启动、完整容量统计、拖入应用检查、扫描目录管理、签名与苹果启动政策评估、查看应用隐私用途并管理系统授权、安装收据与后台组件核对、下载安装包回收、关联文件卸载、缓存清理、设置重置、疑似残留检查、用户启动代理启停、传统扩展管理、浏览器扩展清单及声明权限、应用详情和兼容性筛选、批量卸载、网络用量采样、开发者及苹果商店版本检查、默认打开方式、清理记录与单项恢复。所有清理均先显示文件并要求确认。") { EmptyView() }
                infoCard("当前版本的边界", symbol: "info.circle", text: "这是独立开发的本地应用，不是原厂产品。尚未实现原版的联网阻断、完整商业更新数据库、一键批量升级。关联识别以应用标识和已知目录为依据，无法保证找到每个文件。整机组件可查看归属并检查开发者卸载程序。扫描位置可查看访问结果。苹果电脑系统 27 起，实际隐私授权需在系统设置查看和调整。初始体积为估算，可点“完整统计”后台测量逻辑大小。自动提醒仅关注清舟监测期间新发生的删除；受限目录无法确认时会提示权限问题。") { EmptyView() }
                infoCard("数据与恢复", symbol: "externaldrive", text: "默认在本机分析文件名、路径和应用元数据。检查开发者更新会连接应用声明的来源。单独查询苹果商店时，清舟向苹果发送所选应用的标识和商店地区。主动进行苹果启动政策评估时，系统可能联系苹果验证服务。个人数据和疑似残留不会默认勾选。清理仅移入废纸篓；清空废纸篓后将无法通过清舟恢复。") { EmptyView() }
                ScanRootsView()
                if !model.warnings.isEmpty {
                    infoCard("本次扫描提示", symbol: "exclamationmark.circle", text: model.warnings.joined(separator: "\n")) { EmptyView() }
                }
                Text("清舟 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · 本机独立版本").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            }.padding(28)
        }
    }
    private func infoCard<Content: View>(_ title: String, symbol: String, text: String, @ViewBuilder actions: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(teal)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(6).textSelection(.enabled)
            actions()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
    }
}
