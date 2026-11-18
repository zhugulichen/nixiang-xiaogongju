import Foundation
#if !DETAILS_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private struct DetailsFailure: Error { let message: String }
private enum DetailsChecks {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw DetailsFailure(message: message) }
    }

    static func run() async throws -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("清舟详情-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let host = DetailsHost(architecture: "arm64", system: .init(majorVersion: 14, minorVersion: 5, patchVersion: 0))
        let arm = AppExecutableSlice(name: "arm64", desktop: true, minimum: "12.0")
        let intel = AppExecutableSlice(name: "x86_64", desktop: true, minimum: "11.0")
        func status(_ slices: [AppExecutableSlice], global: String? = nil, perArch: [String: String] = [:], nativeOnly: Bool = false) -> AppCompatibilityStatus {
            AppDetailsService.assess(slices: slices, host: host, globalMinimum: global, perArchitecture: perArch, requiresNative: nativeOnly).0
        }
        func makeApp(_ fields: [String: Any] = [:]) throws -> (AppRecord, URL) {
            let dir = root.appendingPathComponent(UUID().uuidString + ".app")
            let binary = dir.appendingPathComponent("Contents/MacOS/main")
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "test.qingzhou.details", "CFBundleExecutable": "main", "CFBundleVersion": "42"].merging(fields) { _, new in new }
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: dir.appendingPathComponent("Contents/Info.plist"))
            return (AppRecord(url: dir, name: "临时详情验收", bundleID: "test.qingzhou.details", version: "1.2"), binary)
        }
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            count += 1
            print("通过：" + name)
        }

        try test("原生架构的系统要求满足") {
            try require(status([intel, arm], global: "14.5.0") == .native, "应优先使用原生架构")
        }
        try test("仅英特尔切片需要转译") {
            try require(status([intel]) == .requiresTranslation, "转译状态有误")
        }
        try test("可选架构的最低要求单独判断") {
            try require(status([arm, intel], perArch: ["arm64": "15.0"]) == .requiresTranslation, "应考虑仍可用的英特尔切片")
        }
        try test("全局门槛不能被较低的分架构门槛覆盖") {
            try require(status([arm], global: "15.0", perArch: ["arm64": "10.0"]) == .incompatible, "全局门槛失效")
        }
        try test("编译时最低版本也会限制运行") {
            try require(status([.init(name: "arm64", desktop: true, minimum: "15.0")]) == .incompatible, "遗漏编译门槛")
        }
        try test("声明只能原生执行时不能推荐转译") {
            try require(status([intel], nativeOnly: true) == .incompatible, "原生执行约束失效")
        }
        try test("旧三十二位程序不能归为可转译") {
            try require(status([.init(name: "i386", desktop: true, minimum: nil)]) == .incompatible, "旧架构误判")
        }
        try test("未识别架构、移动平台或缺失平台保持未知") {
            for item in [AppExecutableSlice(name:"future", desktop: true, minimum: nil), .init(name:"arm64", desktop: false, minimum: nil), .init(name:"arm64", desktop: nil, minimum: nil)] {
                try require(status([item]) == .unknown, "平台被错误判定为兼容")
            }
        }
        try test("损坏版本号不猜测") {
            try require(status([arm], global: "14.beta") == .unknown && status([intel], perArch: ["x86_64": ""]) == .unknown, "无效版本误判")
        }
        try test("真实可执行格式、构建号与应用包日期") {
            let (app, binary) = try makeApp(["LSMinimumSystemVersion": "12.0"])
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
            let item = try AppDetailsService.read(app: app, host: .current, includeLastUsed: false)
            try require(item.compatibility == .native && !item.architectures.isEmpty, "系统程序副本未读出原生架构 \(item.message) \(item.architectures) \(DetailsHost.current)")
            try require(item.buildVersion == "42" && item.executableURL?.path == binary.path, "主程序信息错误")
            try require(item.createdAt != nil && item.modifiedAt != nil && item.lastUsedAt == nil, "文件日期冒充使用记录")
        }
        try test("脚本不被执行或判定为原生应用") {
            let (app, binary) = try makeApp()
            let marker = root.appendingPathComponent("绝不能生成")
            try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: binary, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            let info = try AppDetailsService.read(app: app, host: host, includeLastUsed: false)
            try require(info.compatibility == .unknown && !fm.fileExists(atPath: marker.path), "脚本运行或误判")
        }
        try test("伪造主程序路径和符号链接受限") {
            let (app, _) = try makeApp(["CFBundleExecutable": "../../outside"])
            let a = try AppDetailsService.read(app: app, host: host, includeLastUsed: false)
            try require(a.executableURL == nil && a.compatibility == .unknown, "越界文件名未拒绝")
            let (linked, path) = try makeApp()
            try fm.createSymbolicLink(atPath: path.path, withDestinationPath: "/usr/bin/true")
            let b = try AppDetailsService.read(app: linked, host: host, includeLastUsed: false)
            try require(b.executableURL == nil && b.compatibility == .unknown, "链接主程序未拒绝")
        }
        try test("手机包装应用显示由系统判断") {
            let (app, _) = try makeApp()
            try fm.createSymbolicLink(atPath: app.url.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Inner.app")
            let value = try AppDetailsService.read(app: app, host: host, includeLastUsed: false)
            try require(value.compatibility == .unknown && value.message.contains("手机"), "包装应用误判")
        }
        try test("扫描后被不同标识应用替换") {
            let (app, _) = try makeApp(["CFBundleIdentifier":"test.other"])
            let info = try AppDetailsService.read(app: app, host: host, includeLastUsed: false)
            try require(info.executableURL == nil && info.message.contains("更换"), "未发现标识变化")
        }
        try test("应用标识缺失时不沿用旧扫描身份") {
            let (app, binary) = try makeApp()
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
            let infoURL = app.url.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
            info.removeValue(forKey: "CFBundleIdentifier")
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: infoURL)
            let value = try AppDetailsService.read(app: app, host: host, includeLastUsed: false)
            try require(value.compatibility == .unknown && value.executableURL == nil && value.message.contains("身份"), "缺失标识仍继续发布扫描结果")
        }
        try test("祖先符号链接不能作为应用路径入口") {
            let (app, binary) = try makeApp()
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
            let link = root.appendingPathComponent("linked-parent")
            try fm.createSymbolicLink(at: link, withDestinationURL: app.url.deletingLastPathComponent())
            let alias = AppRecord(url: link.appendingPathComponent(app.url.lastPathComponent), name: app.name, bundleID: app.bundleID, version: app.version)
            let value = try AppDetailsService.read(app: alias, host: host, includeLastUsed: false)
            try require(value.compatibility == .unknown && value.executableURL == nil, "祖先链接绕过只读路径验证")
        }
        try test("无效通用程序头保守处理") {
            let (app, binary) = try makeApp()
            try Data([0xca,0xfe,0xba,0xbe,0xff,0xff,0xff,0xff]).write(to: binary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            let info = try AppDetailsService.read(app: app, host: host, includeLastUsed: false)
            try require(info.compatibility == .unknown && info.architectures.isEmpty, "损坏头部误判")
        }
        let (app, _) = try makeApp()
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await AppDetailsService.inspect(app: app); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        try test("取消检查会终止读取") { try require(cancelled, "已取消任务仍发布结果") }
        return count
    }
}

#if DETAILS_STANDALONE_TESTS
@main struct AppDetailsRunner {
    static func main() async throws {
        let count = try await DetailsChecks.run()
        print("应用详情与兼容性：\(count) 项检查通过")
    }
}
#else
final class AppDetailsTests: XCTestCase {
    func testDetailsChecks() async throws { _ = try await DetailsChecks.run() }
}
#endif
