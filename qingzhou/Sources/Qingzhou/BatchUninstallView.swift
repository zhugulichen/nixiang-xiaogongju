import SwiftUI
import CleanCore

struct BatchUninstallView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var search = ""
    private var apps: [AppRecord] {
        model.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                TextField("搜索要批量卸载的应用", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.top, 18)
                HStack {
                    Text("已选 \(model.batchAppIDs.count) 个应用").font(.caption)
                    Spacer()
                    Button("清空") { model.clearBatch() }.disabled(model.busy || model.modifyingFiles)
                }.padding(.horizontal, 16)
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(apps) { app in
                            HStack(spacing: 10) {
                                Toggle("批量选择 \(app.name)", isOn: Binding(get: { model.batchAppIDs.contains(app.id) }, set: { model.toggleBatch(app, selected: $0) }))
                                    .labelsHidden().toggleStyle(.checkbox)
                                    .disabled(app.isProtected || model.isSkipped(app) || !ApplicationLocationService.applicationIsInScope(app.url, roots: model.roots) || model.busy || model.modifyingFiles)
                                AppIcon(url: app.url, size: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(app.isProtected ? "受保护" : (model.isSkipped(app) ? "跳过名单保护" : app.version)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(11).background(model.batchAppIDs.contains(app.id) ? teal.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }.padding(.horizontal, 9)
                }
                Button("分析选中应用的关联文件") { model.analyzeBatch() }
                    .buttonStyle(.borderedProminent).disabled(model.batchAppIDs.isEmpty || model.busy || model.fileBusy || model.modifyingFiles)
                    .padding(.bottom, 18)
            }.frame(width: 305)
            Divider()
            VStack(spacing: 0) {
                Notice(text: "选择应用并分析后，逐项核对文件。缓存和日志可默认选择；个人数据、共享路径不会默认勾选。系统应用与清舟自身受保护。", symbol: "square.stack.3d.up").padding(.top, 18)
                if !model.batchWarnings.isEmpty {
                    Text(model.batchWarnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 14)
                }
                if model.batchPlanReady || model.fileBusy { FileListView(useSearch: false) }
                else { EmptyViewCard(symbol: "square.stack.3d.up", title: "一次核对多个应用", subtitle: "先在左侧勾选应用，再分析关联文件。确认完整路径后统一移入废纸篓。") }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已选 \(model.selectedFiles.count) 个文件项目").font(.caption)
                        Text(DisplayFormat.bytes(model.selectedBytes)).font(.title2).foregroundStyle(teal)
                    }
                    Spacer()
                    Button("取消文件选择") { model.selectedFiles = [] }.disabled(model.busy || model.modifyingFiles)
                    Button("检查并清理") { model.reviewSelection() }.buttonStyle(.borderedProminent)
                        .disabled(!model.batchPlanReady || model.selectedFiles.isEmpty || model.busy || model.fileBusy || model.modifyingFiles)
                }.padding(20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
