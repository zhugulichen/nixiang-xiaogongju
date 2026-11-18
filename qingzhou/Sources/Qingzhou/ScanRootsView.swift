import SwiftUI
import Foundation

struct ScanRootsView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var folderPath = ""
    @ViewState private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("扫描位置", systemImage: "folder").font(.system(size: 16, weight: .semibold)).foregroundStyle(teal)
            Text("内建位置始终保留。添加的文件夹会同时用于应用扫描和废纸篓自动提醒。").font(.caption).foregroundStyle(.secondary)
            ForEach(model.builtInRoots, id: \.path) { url in
                HStack(alignment: .top) {
                    Text(url.path).textSelection(.enabled)
                    Spacer()
                    Text("内建").foregroundStyle(.secondary)
                }.font(.caption)
            }
            if !model.extraRoots.isEmpty {
                Divider()
                ForEach(model.extraRoots, id: \.self) { path in
                    HStack(alignment: .top) {
                        Text(path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("移除") { model.removeRoot(path) }.disabled(model.busy || model.modifyingFiles || model.showConfirmation)
                    }.font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("拖入专用应用文件夹，或粘贴路径", systemImage: "folder.badge.plus").font(.callout)
                HStack {
                    TextField("例如 /Users/你的用户名/Applications", text: $folderPath)
                        .textFieldStyle(.roundedBorder).onSubmit { addPath() }
                    Button("添加") { addPath() }.disabled(folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("可在访达选中文件夹，同时按 ⌥（选项键）＋⌘（命令键）＋C 复制路径，然后粘贴到这里。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.busy { ProgressView(model.activity).controlSize(.small) }
            }.padding(14).background(teal.opacity(targeted ? 0.15 : 0.05), in: RoundedRectangle(cornerRadius: 10))
                .disabled(model.busy || model.modifyingFiles || model.showConfirmation)
                .dropDestination(for: URL.self) { urls, _ in
                    guard urls.count == 1, let url = urls.first, !model.busy, !model.modifyingFiles, !model.showConfirmation else { return false }
                    model.addRoot(url); return true
                } isTargeted: { targeted = $0 }
            Text("移除只停止扫描该位置，不会删除文件。该位置的旧清理记录在恢复前可能需要重新添加目录。拖入窗口的应用仅在本次运行中临时显示，不会自动增加扫描范围。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
    }
    private func addPath() {
        guard !model.busy, !model.modifyingFiles, !model.showConfirmation else { return }
        var path = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { model.alert = "请粘贴以 / 开头的完整文件夹路径。"; return }
        model.addRoot(URL(fileURLWithPath: path, isDirectory: true))
    }
}

struct ScanRootsSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            ScrollView { ScanRootsView() }
            HStack { Spacer(); Button("完成") { model.showScanRoots = false }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 620, height: 450)
            .alert("清舟", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                Button("知道了", role: .cancel) { model.alert = nil }
            } message: { Text(model.alert ?? "") }
    }
}
