import SwiftUI
import AppKit

private final class MainWindow: NSWindow {
    var storeInMenuBar: (() -> Void)?
    override func miniaturize(_ sender: Any?) { storeInMenuBar?() }
    override func performMiniaturize(_ sender: Any?) { storeInMenuBar?() }
}

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppLifecycle?
    private var mainWindow: NSWindow?
    private var readyForOpenEvents = false
    private var launchURLs: [URL] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        showMain()
        AppModel.shared.scan()
        CleanupWatch.shared.start(roots: AppModel.shared.roots)
        readyForOpenEvents = true
        if !launchURLs.isEmpty {
            let urls = launchURLs; launchURLs = []
            AppModel.shared.openApplications(urls)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.modifyingFiles else { return .terminateNow }
        AppModel.shared.alert = "正在移动或恢复文件，请等本次操作完成后再退出清舟。"
        showMain(); return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening an already visible app must preserve its file panels and modal sheets.
        if mainWindow?.isVisible != true { showMain() }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) { CleanupWatch.shared.refreshLoginStatus() }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard readyForOpenEvents else { launchURLs.append(contentsOf: urls); return }
        showMain()
        _ = AppModel.shared.openApplications(urls)
    }
    private func storeMain() {
        guard let window = mainWindow, window.attachedSheet == nil else { return }
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        storeMain()
        return false
    }
    func showMain() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if mainWindow == nil {
            let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "清舟"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 1080, height: 700); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(AppModel.shared))
            window.delegate = self
            window.storeInMenuBar = { [weak self] in self?.storeMain() }
            window.standardWindowButton(.miniaturizeButton)?.toolTip = "收到菜单栏"
            window.center(); mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct WatchMenu: View {
    @ObservedObject var watch = CleanupWatch.shared
    var body: some View {
        Text(watch.enabled ? watch.status : "监测已暂停")
        Button("打开清舟") { AppLifecycle.shared?.showMain() }
        Button("深度清理提醒（\(watch.candidates.count)）") { AppLifecycle.shared?.showMain(); AppModel.shared.changePage(.smartCleanup) }
        Button(watch.enabled ? "暂停自动提醒" : "开启自动提醒") { watch.setEnabled(!watch.enabled) }
        Divider()
        Button("退出清舟") { NSApp.terminate(nil) }
    }
}
