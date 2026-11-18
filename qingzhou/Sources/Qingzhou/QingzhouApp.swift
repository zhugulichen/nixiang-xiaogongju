import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CleanCore

@main struct QingzhouApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var delegate
    @StateObject private var model = AppModel.shared
    init() {
        if CommandLine.arguments.contains("--self-check") {
            let report = AppScanner().scanApplications()
            let result: [String: Any] = ["应用数量": report.apps.count, "受保护数量": report.apps.filter(\.isProtected).count, "警告": report.warnings, "已执行删除": false]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) { print(string) }
            exit(report.apps.isEmpty ? 1 : 0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    var body: some Scene {
        MenuBarExtra("清舟", systemImage: "sailboat") { WatchMenu() }
        Settings { WatchSettingsView().padding(25).frame(width: 480) }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择应用…") {
                    AppLifecycle.shared?.showMain()
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true; panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.applicationBundle]
                    panel.message = "选择要检查的应用；也可以直接将应用拖入清舟窗口。"
                    if panel.runModal() == .OK { model.openApplications(panel.urls) }
                }.keyboardShortcut("o").disabled(model.busy || model.modifyingFiles || model.showConfirmation)
                Button("重新扫描") { model.scan() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Button("清舟使用说明") { model.changePage(.privacy) }
            }
        }
    }
}
