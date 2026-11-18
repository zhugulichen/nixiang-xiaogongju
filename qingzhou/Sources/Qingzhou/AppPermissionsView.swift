import SwiftUI
import AppKit
import CleanCore

struct AppPermissionsView: View {
    let app: AppRecord
    @Environment(\.dismiss) private var dismiss
    @ViewState private var declarations: [PermissionDeclaration] = []
    @ViewState private var report: PrivacyAccessReport?
    @ViewState private var readable = true
    @ViewState private var loading = true
    @ViewState private var actual = true
    @ViewState private var pending: PrivacyAccessGroup?
    @ViewState private var feedback: String?
    @ViewState private var settingsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                AppIcon(url: app.url, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("应用隐私权限").font(.title2.bold())
                    Text(app.name + " · " + app.bundleID).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(loading)
            }
            HStack {
                Picker("显示内容", selection: $actual) {
                    Text(report?.requiresSystemSettings == true ? "系统授权设置" : "系统授权记录").tag(true)
                    Text("开发者用途声明").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 290)
                Spacer()
                if !actual || report?.requiresSystemSettings != true {
                    Button("刷新") { Task { await refresh() } }.disabled(loading)
                }
                Button("系统隐私设置") { openPrivacySettings() }
            }
            if settingsError {
                Text("未能打开设置。请在系统设置中选择“隐私与安全性”。")
                    .font(.callout).foregroundStyle(.orange)
            }
            if loading {
                ProgressView("正在核对…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if actual && report?.requiresSystemSettings == true {
                            systemSettingsHelp
                        } else if actual {
                            if let feedback { Text(feedback).font(.callout).foregroundStyle(teal) }
                            ForEach(report?.warnings ?? [], id: \.self) { text in
                                Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            }
                            if let report, report.groups.isEmpty {
                                Text(report.warnings.isEmpty ? "在当前用户和全机记录中未找到这个主程序的决定。" : "在已读到的记录中未发现这个主程序的决定。")
                                    .font(.headline)
                            }
                            ForEach(report?.groups ?? []) { group in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(group.title).font(.headline)
                                        Spacer()
                                        if group.allowsReset {
                                            Button("撤销此项授权…") { pending = group }
                                                .accessibilityLabel("撤销" + group.title + "授权")
                                        }
                                    }
                                    ForEach(Array(group.records.enumerated()), id: \.offset) { _, record in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(record.source + " · " + record.status)
                                            if let target = record.target { Text("目标：" + target).font(.caption).textSelection(.enabled) }
                                            if let note = record.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            }
                            Text("显示此主程序在本机可读取的系统决定。位置、本地网络和独立辅助程序可能使用其他记录。未记录的权限可能在首次使用时询问。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if declarations.isEmpty {
                            Text(readable ? "主程序没有声明这些常见权限的用途。" : "当前无法读取应用的用途声明。")
                        } else {
                            ForEach(declarations) { declaration in
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(declaration.title, systemImage: declaration.symbol).font(.headline).foregroundStyle(teal)
                                    Text(declaration.purpose).font(.callout).textSelection(.enabled)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 3)
                }
            }
        }.padding(24).frame(width: 700, height: 590)
        .interactiveDismissDisabled(loading)
        .task(id: app.id) { await refresh() }
        .alert(item: $pending) { group in
            let scope = group.id == "AppleEvents" ? "此项包含这个应用已登记的所有控制目标。" : ""
            return Alert(title: Text("撤销“" + group.title + "”授权？"),
                message: Text("清舟会请系统重置“" + app.name + "”（" + app.bundleID + "）的这一项决定。系统按应用标识处理，相同标识的副本共用该范围。" + scope + "下次使用时系统可重新询问。"),
                primaryButton: .destructive(Text("确认撤销")) { Task { await revoke(group) } },
                secondaryButton: .cancel(Text("取消")))
        }
    }

    private var systemSettingsHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请在系统设置查看和更改实际授权").font(.headline)
            Text("从 macOS 27 起，苹果限制应用直接读取系统授权记录，完全磁盘访问权限也无法读取这些记录。打开下方类别后，在系统列表中查找“\(app.name)”。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(PrivacySettingsSection.allCases) { section in
                    Button {
                        openPrivacySettings(section)
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(5)
                    }
                }
            }
        }
    }

    private func openPrivacySettings(_ section: PrivacySettingsSection? = nil) {
        let general = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
        let url = section.map { URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + $0.rawValue)! } ?? general
        settingsError = !NSWorkspace.shared.open(url) && (section == nil || !NSWorkspace.shared.open(general))
    }

    @MainActor private func refresh() async {
        loading = true; feedback = nil
        let target = app
        let (declaration, audit) = await Task.detached(priority: .utility) {
            (PermissionDeclaration.read(at: target.url), PrivacyAccessService().inspect(target))
        }.value
        guard !Task.isCancelled else { return }
        readable = declaration.readable; declarations = declaration.items
        report = audit; loading = false
    }

    @MainActor private func revoke(_ group: PrivacyAccessGroup) async {
        guard !loading else { return }
        loading = true; feedback = nil
        let target = app
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try PrivacyAccessService().revoke(group, for: target)
            }.value
            report = updated
            if updated.groups.contains(where: { $0.id == group.id }) || !updated.warnings.isEmpty {
                feedback = "系统已处理重置请求。请核对此次刷新后的授权记录及读取提示。"
            } else {
                feedback = "已重置“" + group.title + "”，并核实相应记录已移除。"
            }
        } catch { feedback = error.localizedDescription }
        loading = false
    }
}

private enum PrivacySettingsSection: String, CaseIterable, Identifiable {
    case camera = "Camera", microphone = "Microphone", screenRecording = "ScreenCapture"
    case photos = "Photos", files = "FilesAndFolders", fullDiskAccess = "AllFiles"
    case accessibility = "Accessibility", automation = "Automation"

    var id: Self { self }
    var title: String {
        switch self {
        case .camera: return "相机"
        case .microphone: return "麦克风"
        case .screenRecording: return "屏幕与系统录音"
        case .photos: return "照片"
        case .files: return "文件与文件夹"
        case .fullDiskAccess: return "完全磁盘访问权限"
        case .accessibility: return "辅助功能"
        case .automation: return "自动化"
        }
    }
    var symbol: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .screenRecording: return "record.circle"
        case .photos: return "photo"
        case .files: return "folder"
        case .fullDiskAccess: return "externaldrive"
        case .accessibility: return "accessibility"
        case .automation: return "gearshape.2"
        }
    }
}

private struct PermissionDeclaration: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let purpose: String

    static func read(at url: URL) -> (readable: Bool, items: [Self]) {
        guard let info = ApplicationMetadata.information(at: url) else { return (false, []) }
        let fields: [(String, String, String)] = [
            ("NSCameraUsageDescription", "相机", "camera"),
            ("NSMicrophoneUsageDescription", "麦克风", "mic"),
            ("NSContactsUsageDescription", "通讯录", "person.crop.rectangle"),
            ("NSCalendarsUsageDescription", "日历", "calendar"),
            ("NSCalendarsFullAccessUsageDescription", "日历完整访问", "calendar"),
            ("NSCalendarsWriteOnlyAccessUsageDescription", "添加日历事项", "calendar.badge.plus"),
            ("NSRemindersUsageDescription", "提醒事项", "checklist"),
            ("NSRemindersFullAccessUsageDescription", "提醒事项完整访问", "checklist"),
            ("NSPhotosUsageDescription", "照片", "photo"),
            ("NSPhotoLibraryUsageDescription", "照片图库", "photo.on.rectangle"),
            ("NSPhotoLibraryAddUsageDescription", "向图库添加照片", "photo.badge.plus"),
            ("NSLocationUsageDescription", "位置", "location"),
            ("NSLocationWhenInUseUsageDescription", "使用期间的位置", "location"),
            ("NSLocationAlwaysAndWhenInUseUsageDescription", "持续位置访问", "location.fill"),
            ("NSAppleEventsUsageDescription", "自动控制其他应用", "gearshape.2"),
            ("NSBluetoothAlwaysUsageDescription", "蓝牙", "antenna.radiowaves.left.and.right"),
            ("NSBluetoothPeripheralUsageDescription", "蓝牙外设", "antenna.radiowaves.left.and.right"),
            ("NSSpeechRecognitionUsageDescription", "语音识别", "waveform"),
            ("NSDesktopFolderUsageDescription", "桌面文件夹", "desktopcomputer"),
            ("NSDocumentsFolderUsageDescription", "文稿文件夹", "doc"),
            ("NSDownloadsFolderUsageDescription", "下载文件夹", "arrow.down.circle"),
            ("NSNetworkVolumesUsageDescription", "网络磁盘", "externaldrive.connected.to.line.below"),
            ("NSRemovableVolumesUsageDescription", "可移动磁盘", "externaldrive"),
            ("NSLocalNetworkUsageDescription", "本地网络", "network"),
            ("NSSystemAdministrationUsageDescription", "系统管理", "lock.shield"),
        ]
        return (true, fields.compactMap { key, title, symbol in
            guard let text = info[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Self(id: key, title: title, symbol: symbol, purpose: String(text.prefix(8_000)))
        })
    }
}
