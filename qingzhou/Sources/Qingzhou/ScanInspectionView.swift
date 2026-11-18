import SwiftUI
import CleanCore

struct DirectoryScanView: View {
    @Environment(\.dismiss) private var dismiss
    let directories: [DirectoryScanStatus]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫描位置").font(.title2.bold())
            Text("状态记录本次列举目录的结果。文件内容和占用空间可能另受读取权限限制。")
                .font(.caption).foregroundStyle(.secondary)
            List(directories) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(row.outcome.rawValue).foregroundStyle(row.incomplete ? Color.orange : .secondary); Text(row.detail).font(.caption) }
                    Text(row.url.path).font(.caption).textSelection(.enabled)
                }.padding(.vertical, 2)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 630, height: 465)
    }
}

private struct AuditApplication: Identifiable {
    let app: AppRecord
    let original: URL
    var id: String { original.standardizedFileURL.path }
}

struct InstallationAuditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let app: AppRecord?
    let original: URL?
    @ViewState private var removed: [AuditApplication] = []
    @ViewState private var selected = ""
    @ViewState private var report: InstallationAuditReport?
    @ViewState private var error: String?
    @ViewState private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安装收据与后台组件").font(.title2.bold())
            if let app { Text(app.name + " · " + (original ?? app.url).path).font(.caption).textSelection(.enabled) }
            else {
                Picker("查看范围", selection: $selected) {
                    Text("全部第三方后台组件").tag("")
                    ForEach(removed) { record in Text("已移走 · " + record.original.lastPathComponent).tag(record.id) }
                }
            }
            if let report {
                if app != nil || !selected.isEmpty {
                    Text(report.receipts.isEmpty ? "未检出归属此应用路径的第三方安装收据" : "安装收据 " + report.receipts.sorted().joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                List {
                    ForEach(report.uninstallers, id: \.path) { url in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("同一开发团队的卸载程序")
                                Text(url.path).font(.caption).textSelection(.enabled)
                            }
                            Spacer()
                            Button("显示卸载程序") { model.reveal(url) }
                        }
                    }
                    ForEach(report.notes, id: \.self) { note in Text(note).font(.caption).foregroundStyle(.orange) }
                    if report.components.isEmpty { Text("在已核对范围内没有发现匹配的包外文件。") }
                    ForEach(report.components) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(item.url.lastPathComponent); if let state = item.state { Text(state).font(.caption).foregroundStyle(teal) } }
                                Text(item.url.path).font(.caption).textSelection(.enabled)
                                Text(item.evidence).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("在访达查看") { model.reveal(item.url) }
                        }.padding(.vertical, 3)
                    }
                }
            } else if let error { Text(error).foregroundStyle(.orange); Spacer() }
            else { ProgressView("正在核对服务状态与安装收据…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text("收据可能涵盖同套件的多个应用。移除整机服务请使用开发者提供的卸载程序。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("管理用户启动代理") { dismiss(); model.changePage(.startup) }
                Button("打开登录项设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                Link("苹果卸载说明", destination: URL(string: "https://support.apple.com/zh-cn/102610")!)
                Spacer()
                Button("重新检查") { generation = UUID() }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 710, height: 515)
        .onChange(of: selected) { _, _ in generation = UUID() }
        .task(id: generation) {
            report = nil; error = nil
            if app == nil {
                let trash = model.trash
                let history = await Task.detached { trash.history() }.value
                guard !Task.isCancelled else { return }
                var seen = Set<String>()
                removed = history.flatMap(\.entries).compactMap { entry in
                    guard entry.originalURL.pathExtension.lowercased() == "app", !entry.restored, entry.error == nil,
                          let id = entry.ownerBundleID, let location = entry.trashURL,
                          !FileManager.default.fileExists(atPath: entry.originalURL.path),
                          seen.insert(entry.originalURL.path).inserted else { return nil }
                    return AuditApplication(app: AppRecord(url: location, name: entry.originalURL.deletingPathExtension().lastPathComponent,
                                                           bundleID: id, version: ""), original: entry.originalURL)
                }
            }
            let context = removed.first { $0.id == selected }
            let target = app ?? context?.app
            let path = original ?? context?.original
            let work = Task.detached(priority: .userInitiated) { try InstallationAudit().inspect(app: target, originalURL: path) }
            do {
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if !Task.isCancelled { report = value }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
