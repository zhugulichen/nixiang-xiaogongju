import SwiftUI
import CleanCore

struct SmartCleanupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watch = CleanupWatch.shared
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WatchSettingsView()
                    Divider()
                    Text("待检查（\(watch.candidates.count)）").font(.headline)
                    ForEach(watch.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 9) {
                            Button { model.loadDeleted(candidate) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(candidate.app.name).font(.headline)
                                    Text(candidate.detectedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            HStack {
                                Button("忽略应用") { watch.ignore(candidate) }
                                Button("不清理") { watch.dismiss(candidate); model.reconcileDeletedCandidates(watch.candidates) }
                            }.font(.caption)
                        }.disabled(model.modifyingFiles).padding(13).background(model.deletedContext?.id == candidate.id ? teal.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if watch.candidates.isEmpty { Text("等待新的卸载操作。改名、移动到普通文件夹和安装更新不会触发提醒。").font(.caption).foregroundStyle(.secondary) }
                }.padding(20)
            }.frame(width: 310)
            Divider()
            VStack(spacing: 0) {
                if let context = model.deletedContext {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(context.app.name).font(.title2.bold())
                        Text("应用本体已在废纸篓。这里只列出可能仍留在电脑上的关联文件。").font(.caption).foregroundStyle(.secondary)
                        Text(context.app.url.path).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    Notice(text: "聊天记录、项目、账号及容器数据不会默认选择。恢复或重装应用后，本次清理候选会失效。")
                    FileListView(useSearch: false)
                    HStack {
                        VStack(alignment: .leading) { Text("已选 \(model.selectedFiles.count) 项").font(.caption); Text(DisplayFormat.bytes(model.selectedBytes)).font(.title2).foregroundStyle(teal) }
                        Spacer()
                        Button("检查并清理") { model.reviewSelection() }.buttonStyle(.borderedProminent).disabled(model.selectedFiles.isEmpty || model.busy || model.fileBusy)
                    }.padding(20)
                } else {
                    EmptyViewCard(symbol: "bell.badge", title: "卸载之后，再检查一次", subtitle: "将应用拖入废纸篓，清舟会在确认后弹窗提醒。点击“查看关联文件”，再逐项决定清理内容。")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
