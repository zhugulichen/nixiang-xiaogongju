import SwiftUI
import CleanCore

struct UpdatesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var center: ApplicationUpdateCenter
    @ViewState private var filter = Filter.all
    @ViewState private var search = ""
    @ViewState private var storeApp: AppRecord?
    @ViewState private var showIgnored = false
    @ViewState private var region = Locale.current.region?.identifier ?? ""

    private enum Filter: String, CaseIterable {
        case all = "全部", available = "可更新", failed = "检查未完成", developer = "开发者更新源", store = "苹果商店"
    }
    private var inventory: [AppRecord] { model.apps.filter { !$0.isProtected || $0.hasStoreReceipt } }
    private var rows: [AppRecord] {
        inventory.filter { app in
            guard search.isEmpty || [app.name, app.bundleID, app.id].contains(where: { $0.localizedCaseInsensitiveContains(search) }) else { return false }
            let source = ApplicationUpdateSource.source(for: app)
            switch filter {
            case .all: return true
            case .available: return center.results[app.id]?.status == .available
            case .failed: return center.results[app.id]?.status == .failed
            case .developer: return source == .developer
            case .store: return source == .store
            }
        }.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
    private func rank(_ app: AppRecord) -> Int {
        if center.isIgnored(app) { return 4 }
        if center.results[app.id]?.status == .available { return 0 }
        switch ApplicationUpdateSource.source(for: app) {
        case .developer: return 1
        case .store: return 2
        case .manual: return 3
        }
    }
    private var busy: Bool { center.checking || model.busy || !center.preferencesReadable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                let available = center.results.values.filter { $0.status == .available }.count
                Text("可更新 \(available) · 可检查开发者源 \(center.developerTargets(in: inventory).count) · 商店应用 \(inventory.filter(\.hasStoreReceipt).count)")
                    .font(.headline)
                Spacer()
                if center.checking {
                    ProgressView().controlSize(.small)
                    Text("\(center.completed)/\(center.total)").font(.caption).monospacedDigit()
                    Button("停止检查") { center.stop() }
                } else {
                    Button("检查开发者更新源") { center.checkFeeds(inventory) }
                        .buttonStyle(.borderedProminent).disabled(busy || center.developerTargets(in: inventory).isEmpty)
                }
            }.padding(.horizontal, 24).padding(.top, 18)
            HStack {
                TextField("搜索应用名称、标识或路径", text: $search).textFieldStyle(.roundedBorder)
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 185)
                Button("已忽略（\(center.ignored.count)）") { showIgnored = true }
            }.padding(.horizontal, 24).padding(.vertical, 14)
            if !center.preferencesReadable {
                Text("更新忽略名单读取失败，已暂停联网检查。请检查本机偏好设置。").font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
            }
            Divider()
            let matches = rows
            if matches.isEmpty {
                EmptyViewCard(symbol: "magnifyingglass", title: "当前没有匹配的应用", subtitle: "可切换筛选或调整搜索条件。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { app in
                            row(app)
                            Divider().padding(.leading, 70)
                        }
                    }
                }
            }
        }
        .sheet(item: $storeApp) { app in
            VStack(alignment: .leading, spacing: 16) {
                Text("查询苹果商店版本").font(.title2.bold())
                Text("将向苹果查询“\(app.name)”的商店版本，并发送以下应用标识和你选择的商店地区。")
                Text(app.bundleID).font(.callout.monospaced()).textSelection(.enabled)
                LabeledContent("商店地区") {
                    TextField("两位地区代码", text: $region).textFieldStyle(.roundedBorder).frame(width: 128)
                }
                Text("初始值来自系统地区。请与苹果账号的商店地区核对，例如中国大陆为 CN，美国为 US。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer(); Button("取消") { storeApp = nil }.keyboardShortcut(.cancelAction)
                    Button("查询版本") {
                        if let current = inventory.first(where: { $0 == app }) { center.checkStore(current, region: region) }
                        storeApp = nil
                    }.keyboardShortcut(.defaultAction).disabled(busy || !StoreUpdateService.supports(region: region) || !inventory.contains(app) || center.isIgnored(app))
                }
            }.padding(24).frame(width: 465)
        }
        .sheet(isPresented: $showIgnored) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("已忽略的应用更新").font(.title2.bold()); Spacer(); Button("完成") { showIgnored = false }.keyboardShortcut(.cancelAction) }
                if center.ignored.isEmpty { Text("没有忽略的应用。").foregroundStyle(.secondary); Spacer() }
                else {
                    ScrollView {
                        ForEach(center.ignored.keys.sorted(), id: \.self) { id in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(center.ignored[id] ?? id)
                                    Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer(); Button("恢复检查") { center.resume(bundleID: id) }.disabled(busy)
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }.padding(22).frame(width: 480, height: 340)
        }
    }

    private func row(_ app: AppRecord) -> some View {
        let source = ApplicationUpdateSource.source(for: app)
        let skipped = center.isIgnored(app)
        return HStack(spacing: 12) {
            AppIcon(url: app.url)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text("\(app.version) · \(source.rawValue)").font(.caption).foregroundStyle(.secondary)
            }.help(app.url.path)
            Spacer(minLength: 6)
            if skipped { Text("已忽略更新").font(.caption).foregroundStyle(.secondary) }
            else if let result = center.results[app.id] {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(result.message).font(.caption).foregroundStyle(result.status == .available ? teal : .secondary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 255, alignment: .trailing)
                    if let url = result.url, source == .store || result.status == .available {
                        Button(source == .store ? "打开商店商品页" : "前往更新来源") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if source != .manual {
                if !skipped {
                    Button(source == .store ? "查询商店版本…" : (center.results[app.id] == nil ? "检查" : "重新检查")) {
                        if source == .store { storeApp = app } else { center.checkFeeds([app]) }
                    }.disabled(busy)
                }
                Menu {
                    if skipped { Button("恢复更新检查") { center.resume(bundleID: app.bundleID) } }
                    else { Button("忽略此应用的更新") { center.ignore(app, in: inventory) } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("\(app.name)的更新选项").menuStyle(.borderlessButton).fixedSize().disabled(busy || app.bundleID.isEmpty)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
}
