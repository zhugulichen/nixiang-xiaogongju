import SwiftUI
import CleanCore

struct ApplicationPreferencesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("清理音效", systemImage: "speaker.wave.2").font(.headline).foregroundStyle(teal)
            Toggle("清理成功时播放系统回收音效", isOn: Binding(get: { model.cleanupSoundEnabled }, set: model.setCleanupSound))
            Text("每批成功清理后反馈一次，遵循系统静音和界面音效设置。通过访达回收时沿用访达自身音效。").font(.caption).foregroundStyle(.secondary)
            Button("试听系统回收音效") {
                if !CleanupSoundFeedback.preview() { model.alert = "系统回收音效暂不可用，文件清理不受影响。" }
            }
            Divider()
            Label("全局跳过名单", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(teal)
            Text("在应用信息菜单中加入名单。保护同标识副本和已核对的关联数据，也停止对应的深度清理提醒；应用仍保留在安装清单中。恢复文件不受此名单阻止。").font(.caption).foregroundStyle(.secondary)
            if let error = model.protectionError {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("重新读取名单") { model.reloadProtectionSettings() }
            }
            if model.skippedApplications.isEmpty { Text("尚未加入应用。").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.skippedApplications) { record in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.name).font(.callout.bold())
                        Text(record.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("保护应用副本、辅助程序及已核对的关联路径").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("移除保护") { model.removeSkippedApplication(record.bundleID) }.disabled(model.protectionError != nil)
                }.padding(.vertical, 6)
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .disabled(model.busy || model.modifyingFiles || model.showConfirmation)
    }
}
