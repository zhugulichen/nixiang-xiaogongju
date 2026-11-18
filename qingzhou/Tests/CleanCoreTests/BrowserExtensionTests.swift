import Foundation
#if !BROWSER_EXTENSIONS_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private struct BrowserCheckError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct BrowserFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    var home: URL { root.appendingPathComponent("Home") }
    let id = String(repeating: "a", count: 32)
    func profile(_ name: String = "Default", folder: String = "Google/Chrome") -> URL {
        home.appendingPathComponent("Library/Application Support/\(folder)/\(name)")
    }
    func json(_ url: URL, _ value: Any) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
    func manifest(_ profile: URL, dir: String = "1.1_0", name: String = "样本", version: String = "1.1", extra: [String: Any] = [:]) throws {
        let data = ["name": name, "version": version].merging(extra) { _, new in new }
        try json(profile.appendingPathComponent("Extensions/\(id)/\(dir)/manifest.json"), data)
    }
    func settings(_ profile: URL, state: [String: Any], file: String = "Secure Preferences") throws {
        try json(profile.appendingPathComponent(file), ["extensions": ["settings": [id: state]]])
    }
    func firefoxPackage(overrides: [String: Any] = [:]) throws -> BrowserExtensionRecord {
        let folder = profile("fixture.default", folder: "Firefox/Profiles")
        let package = folder.appendingPathComponent("extensions/fixture@example.org.xpi")
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4]).write(to: package)
        let addon: [String: Any] = ["type": "extension", "id": "fixture@example.org", "location": "app-profile", "path": package.path,
            "defaultLocale": ["name": "火狐移除样本"], "version": "1", "installTelemetryInfo": ["source": "amo"]]
        try json(folder.appendingPathComponent("extensions.json"), ["addons": [addon.merging(overrides) { _, changed in changed }]])
        return try only()
    }
    func packageURL() -> URL { profile("fixture.default", folder: "Firefox/Profiles").appendingPathComponent("extensions/fixture@example.org.xpi") }
    func scan() throws -> BrowserExtensionReport { try BrowserExtensionService(home: home).scan() }
    func only() throws -> BrowserExtensionRecord {
        let report = try scan()
        let rows = report.records
        guard rows.count == 1 else { throw BrowserCheckError("应恰有一条记录，实际为 \(rows.count)，\(report.warnings.prefix(2))") }
        return rows[0]
    }
}

private typealias BrowserCheck = (String, (BrowserFixture) throws -> Bool)

private let browserChecks: [BrowserCheck] = [
    ("浏览器策略、内置和未登记扩展拒绝发起移除", { f in
        let p = f.profile(); try f.manifest(p)
        for location in [5, 7, 9, 10] {
            try f.settings(p, state: ["location": location, "path": f.id + "/1.1_0"])
            guard try f.only().removal == .unavailable else { return false }
        }
        for location in [1, 4] {
            try f.settings(p, state: ["location": location, "path": f.id + "/1.1_0"])
            guard try f.only().removal == .browserConfirmation else { return false }
        }
        return true
    }),
    ("浏览器移除确认核对指定配置和完整扩展标识", { f in
        let p = f.profile(); try f.manifest(p)
        try f.settings(p, state: ["location": 1, "path": f.id + "/1.1_0"])
        let row = try f.only(), service = BrowserExtensionService(home: f.home)
        guard try service.isRegistered(row) == true, row.detailAddress == "chrome://extensions/?id=" + f.id else { return false }
        try f.json(p.appendingPathComponent("Secure Preferences"), ["extensions": ["settings": [:]]])
        guard try service.isRegistered(row) == false else { return false }
        try Data("损坏".utf8).write(to: p.appendingPathComponent("Secure Preferences"))
        return try service.isRegistered(row) == nil
    }),
    ("旧配置仍有登记时不提前宣称移除成功", { f in
        let p = f.profile(); try f.manifest(p)
        try f.settings(p, state: ["location": 1, "path": f.id + "/1.1_0"])
        let row = try f.only(), service = BrowserExtensionService(home: f.home)
        try f.json(p.appendingPathComponent("Secure Preferences"), ["extensions": ["settings": [:]]])
        try f.settings(p, state: ["location": 1, "path": f.id + "/1.1_0"], file: "Preferences")
        return try service.isRegistered(row) == true
    }),
    ("火狐用户自装包可定向回收并核对登记", { f in
        let row = try f.firefoxPackage(), service = BrowserExtensionService(home: f.home)
        guard case .firefoxPackage = row.removal else { return false }
        let original = f.packageURL(), contents = try Data(contentsOf: original)
        let destination = f.root.appendingPathComponent("fixture-recycled.xpi")
        var calls = 0
        let moved = try service.recycleFirefoxPackage(row, browserRunning: { false }, policyPresent: { false }) { source in
            guard source.standardizedFileURL == original.standardizedFileURL else { throw BrowserCheckError("错误回收路径") }
            calls += 1; try FileManager.default.moveItem(at: source, to: destination); return destination
        }
        guard moved == destination, calls == 1, try Data(contentsOf: destination) == contents,
              try service.isRegistered(row) == true else { return false }
        try f.json(f.profile("fixture.default", folder: "Firefox/Profiles").appendingPathComponent("extensions.json"), ["addons": []])
        guard try service.isRegistered(row) == false else { return false }
        try FileManager.default.moveItem(at: destination, to: original)
        return try Data(contentsOf: original) == contents
    }),
    ("火狐内置、策略、外部和非用户安装来源不可回收", { f in
        for overrides: [String: Any] in [
            ["isSystem": true], ["isBuiltin": true], ["isAppBuiltin": true], ["foreignInstall": true], ["locked": true],
            ["hidden": true], ["temporarilyInstalled": true], ["location": "app-system-defaults"],
            ["path": "/elsewhere/fixture@example.org.xpi"], ["installTelemetryInfo": ["source": "enterprise-policy"]]
        ] {
            guard try f.firefoxPackage(overrides: overrides).removal == .unavailable else { return false }
        }
        return true
    }),
    ("火狐运行或存在管理策略时拒绝移动", { f in
        let row = try f.firefoxPackage(), service = BrowserExtensionService(home: f.home)
        for (running, policy) in [(true, false), (false, true)] {
            do {
                _ = try service.recycleFirefoxPackage(row, browserRunning: { running }, policyPresent: { policy },
                    recycle: { _ in throw BrowserCheckError("不应移动") })
                return false
            } catch let error as BrowserCheckError { throw error } catch {}
        }
        return FileManager.default.fileExists(atPath: f.packageURL().path)
    }),
    ("火狐预览后包被替换或变为链接时拒绝移动", { f in
        let row = try f.firefoxPackage(), service = BrowserExtensionService(home: f.home)
        let source = f.packageURL()
        try Data([0x50, 0x4b, 0x03, 0x04, 9, 9, 9, 9, 9]).write(to: source, options: .atomic)
        do { try service.validateRemoval(row); return false } catch {}
        let other = f.root.appendingPathComponent("outside.xpi")
        try FileManager.default.moveItem(at: source, to: other)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: other)
        return try f.only().removal == .unavailable
    }),
    ("火狐目录不能通过链接逃逸", { f in
        _ = try f.firefoxPackage()
        let profile = f.profile("fixture.default", folder: "Firefox/Profiles")
        let target = f.root.appendingPathComponent("outside-profile")
        try FileManager.default.moveItem(at: profile, to: target)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)
        return try f.scan().records.isEmpty
    }),
    ("浏览器指定版本优先于遗留版本", { f in
        let p = f.profile(); try f.manifest(p); try f.manifest(p, dir: "9.0_0", name: "遗留", version: "9.0")
        try f.settings(p, state: ["path": f.id + "/1.1_0", "disable_reasons": []])
        let row = try f.only(); return row.name == "样本" && row.version == "1.1" && row.state == "未见禁用记录"
    }),
    ("多版本缺失登记时不猜测当前版本", { f in
        let p = f.profile(); try f.manifest(p); try f.manifest(p, dir: "9.0_0", name: "遗留", version: "9.0")
        let row = try f.only(); return row.version == "未确定" && row.state == "状态未确定"
    }),
    ("现代禁用原因与安全配置优先级", { f in
        let p = f.profile(); try f.manifest(p)
        try f.settings(p, state: ["path": f.id + "/1.1_0", "state": 1], file: "Preferences")
        try f.settings(p, state: ["path": f.id + "/1.1_0", "disable_reasons": [4]])
        return try f.only().state == "有禁用记录"
    }),
    ("缺少状态不推断已启用", { f in
        let p = f.profile(); try f.manifest(p)
        try f.settings(p, state: ["path": f.id + "/1.1_0", "from_webstore": true])
        let row = try f.only(); return row.state == "状态未确定" && row.source.contains("商店")
    }),
    ("旧整数禁用原因", { f in
        let p = f.profile(); try f.manifest(p)
        try f.settings(p, state: ["path": f.id + "/1.1_0", "disable_reasons": 2])
        return try f.only().state == "有禁用记录"
    }),
    ("多个浏览器和配置同一标识独立展示", { f in
        for p in [f.profile(), f.profile("Profile 2"), f.profile(folder: "Microsoft Edge"), f.profile(folder: "BraveSoftware/Brave-Browser")] {
            try f.manifest(p)
        }
        let rows = try f.scan().records
        return rows.count == 4 && Set(rows.map(\.id)).count == 4
    }),
    ("本地化名称与分组权限", { f in
        let p = f.profile()
        try f.manifest(p, name: "__MSG_title__", extra: ["default_locale": "en",
             "permissions": ["tabs", "https://old.example/*"], "host_permissions": ["<all_urls>"],
             "optional_permissions": ["storage", "https://optional.example/*"], "optional_host_permissions": ["https://optional.example/*"],
             "content_scripts": [["matches": ["https://script.example/*"]]]])
        try f.json(p.appendingPathComponent("Extensions/\(f.id)/1.1_0/_locales/zh_CN/messages.json"), ["Title": ["message": "本地化的标题"]])
        let row = try f.only()
        return row.name == "本地化的标题" && row.permissions == ["tabs"] && Set(row.sites) == ["<all_urls>", "https://old.example/*"]
            && row.optionalPermissions == ["storage"] && row.optionalSites == ["https://optional.example/*"] && row.scriptSites == ["https://script.example/*"]
    }),
    ("空登记残留不当作扩展", { f in
        try f.settings(f.profile(), state: ["lastpingday": "old"])
        return try f.scan().records.isEmpty
    }),
    ("内建组件仅用浏览器保存的元数据", { f in
        try f.settings(f.profile(), state: ["location": 5, "path": "/outside/browser", "manifest": ["name": "内建组件", "version": "1"]])
        let row = try f.only()
        return row.source == "浏览器内置" && row.name == "内建组件" && !row.note.isEmpty
    }),
    ("扩展路径不能逃逸到配置外部", { f in
        try f.json(f.root.appendingPathComponent("outside/manifest.json"), ["name": "越界内容", "version": "1"])
        try f.settings(f.profile(), state: ["path": f.id + "/../../../../../../../../outside"])
        let r = try f.scan(); return r.records.isEmpty && !r.warnings.isEmpty
    }),
    ("符号链接版本不能引入外部清单", { f in
        let p = f.profile(), link = p.appendingPathComponent("Extensions/\(f.id)/1.1_0")
        let outside = f.root.appendingPathComponent("other")
        try f.json(outside.appendingPathComponent("manifest.json"), ["name": "外部", "version": "2"])
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try f.settings(p, state: ["path": f.id + "/1.1_0"])
        let r = try f.scan(); return r.records.isEmpty && !r.warnings.isEmpty
    }),
    ("损坏配置不妨碍另一个配置", { f in
        let p = f.profile(), other = f.profile("Profile 1")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try Data("无效".utf8).write(to: p.appendingPathComponent("Secure Preferences"))
        try f.manifest(other)
        let r = try f.scan(); return r.records.count == 1 && !r.warnings.isEmpty
    }),
    ("超大清单报告部分读取失败", { f in
        let p = f.profile(), dir = p.appendingPathComponent("Extensions/\(f.id)/1.1_0")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1).write(to: dir.appendingPathComponent("manifest.json"))
        try f.settings(p, state: ["path": f.id + "/1.1_0"])
        let r = try f.scan(); return r.records.isEmpty && !r.warnings.isEmpty
    }),
    ("火狐声明、可选权限与其他附加项分离", { f in
        let file = f.profile("alpha.default", folder: "Firefox/Profiles").appendingPathComponent("extensions.json")
        let addon: [String: Any] = ["type": "extension", "id": "test@example.org", "defaultLocale": ["name": "火狐扩展"],
            "version": "2", "active": true, "userPermissions": ["permissions": ["tabs"], "origins": []],
            "requestedPermissions": ["origins": ["https://a.example/*"]], "optionalPermissions": ["permissions": ["bookmarks"], "origins": ["<all_urls>"]]]
        try f.json(file, ["addons": [addon, ["type": "theme", "id": "theme"]]])
        let row = try f.only()
        return row.name == "火狐扩展" && row.state == "记录为运行中" && row.sites == ["https://a.example/*"] && row.permissions == ["tabs"]
            && row.optionalPermissions == ["bookmarks"] && row.optionalSites == ["<all_urls>"]
    }),
    ("火狐状态矛盾保持未知", { f in
        let file = f.profile("alpha.default", folder: "Firefox/Profiles").appendingPathComponent("extensions.json")
        try f.json(file, ["addons": [["type": "extension", "id": "extension1", "active": true, "userDisabled": true]]])
        return try f.only().state == "状态未确定"
    })
]

private func runBrowserChecks() async throws -> Int {
    for (name, check) in browserChecks {
        let fixture = BrowserFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do { guard try check(fixture) else { throw BrowserCheckError(name) } }
        catch { throw BrowserCheckError(name + "：" + error.localizedDescription) }
        print("通过：" + name)
    }
    let fixture = BrowserFixture()
    let cancelled = Task<Bool, Never> {
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try fixture.scan(); return false }
        catch is CancellationError { return true }
        catch { return false }
    }
    guard await cancelled.value else { throw BrowserCheckError("取消扫描") }
    print("通过：取消扫描")
    return browserChecks.count + 1
}

#if BROWSER_EXTENSIONS_STANDALONE_TESTS
@main struct BrowserExtensionRunner {
    static func main() async throws {
        let count = try await runBrowserChecks()
        print("浏览器扩展：\(count) 项检查通过")
    }
}
#else
final class BrowserExtensionTests: XCTestCase {
    func testBrowserExtensionLibrary() async throws { _ = try await runBrowserChecks() }
}
#endif
