import SwiftUI
import CleanCore

struct AppDetailsView: View {
    let app: AppRecord
    @Environment(\.dismiss) private var dismiss
    @ViewState private var details: AppDetails?
    @ViewState private var loading = true
    @ViewState private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AppIcon(url: app.url, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("应用详情").font(.title2.bold())
                    Text(app.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(details.compatibility.rawValue, systemImage: details.compatibility.symbol).font(.headline)
                        Text(details.message).font(.callout).foregroundStyle(.secondary)
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            row("版本", app.version)
                            row("构建号", details.buildVersion ?? "未提供")
                            row("应用标识", app.bundleID.isEmpty ? "未提供" : app.bundleID)
                            row("应用位置", app.url.path)
                            row("主程序位置", details.executableURL?.path ?? "未能确认")
                            row("主程序架构", details.architectures.isEmpty ? "未能确认" : details.architectures.joined(separator: "、"))
                            row("应用声明的最低系统", details.minimumSystemVersion ?? "未声明")
                            ForEach(details.minimumByArchitecture.keys.sorted(), id: \.self) { arch in
                                row("\(arch) 声明的最低系统", details.minimumByArchitecture[arch] ?? "未声明")
                            }
                            row("应用包创建时间", display(details.createdAt))
                            row("应用包修改时间", display(details.modifiedAt))
                            row("最近使用（系统索引）", display(details.lastUsedAt))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }
            } else if loading {
                ProgressView("读取应用资料…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(failure ?? "尚未取得应用资料。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24).frame(width: 630, height: 580)
        .task(id: app.id) {
            details = nil
            failure = nil
            loading = true
            do {
                let value = try await AppDetailsService.inspect(app: app)
                guard !Task.isCancelled else { return }
                details = value
            } catch {
                guard !Task.isCancelled else { return }
                failure = "读取未完成：" + error.localizedDescription
            }
            loading = false
        }
    }

    private func display(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "系统未提供"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}

@MainActor private final class CompatibilityReader: ObservableObject {
    @Published var rows: [AppDetails] = []
    @Published var reading = false
    @Published var cancelled = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(_ apps: [AppRecord]) {
        task?.cancel()
        rows = []
        reading = true
        cancelled = false
        let ticket = UUID()
        generation = ticket
        task = Task { [weak self] in
            for app in apps.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                guard !Task.isCancelled else { return }
                let item: AppDetails
                do {
                    item = try await AppDetailsService.compatibility(for: app)
                } catch is CancellationError {
                    return
                } catch {
                    var unavailable = AppDetails(app: app)
                    unavailable.message = "读取未完成：" + error.localizedDescription
                    item = unavailable
                }
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.rows.append(item)
            }
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            self.reading = false
            self.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation = UUID()
        cancelled = reading
        reading = false
    }
    deinit { task?.cancel() }
}

struct CompatibilityOverview: View {
    let apps: [AppRecord]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reader = CompatibilityReader()
    @ViewState private var filter: AppCompatibilityStatus?
    @ViewState private var search = ""
    @ViewState private var selected: AppRecord?

    private var rows: [AppDetails] {
        reader.rows.filter {
            (filter == nil || $0.compatibility == filter) &&
                (search.isEmpty || $0.app.name.localizedCaseInsensitiveContains(search) || $0.app.bundleID.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("应用兼容性").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("搜索应用名称或标识", text: $search).textFieldStyle(.roundedBorder)
                Picker("筛选", selection: $filter) {
                    Text("全部结果").tag(Optional<AppCompatibilityStatus>.none)
                    ForEach(AppCompatibilityStatus.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(Optional(item))
                    }
                }.frame(width: 190)
            }
            HStack {
                Text("\(reader.cancelled ? "已取消，已检查" : "已检查") \(reader.rows.count) / \(apps.count) 个应用 · 符合筛选 \(rows.count) 个")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if reader.reading {
                    ProgressView().controlSize(.small)
                    Button("取消检查") { reader.stop() }
                } else {
                    Button("重新检查") { reader.start(apps) }
                }
            }
            Divider()
            if rows.isEmpty {
                Text(reader.reading ? "正在核对应用架构与最低系统要求…" : "当前没有符合条件的应用。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.app.name).font(.headline)
                                    Text(item.message).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(item.compatibility.rawValue, systemImage: item.compatibility.symbol).font(.caption)
                                Button("详情") { selected = item.app }.accessibilityLabel("查看\(item.app.name)的详情")
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
            }
            Text("按主程序架构和最低系统版本筛选。签名、依赖及转译服务会影响实际启动。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 715, height: 550)
        .onAppear { reader.start(apps) }
        .onDisappear { reader.stop() }
        .sheet(item: $selected) { AppDetailsView(app: $0) }
    }
}

private extension AppCompatibilityStatus {
    var symbol: String {
        switch self {
        case .native: return "checkmark.circle"
        case .requiresTranslation: return "arrow.left.arrow.right"
        case .incompatible: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }
}
