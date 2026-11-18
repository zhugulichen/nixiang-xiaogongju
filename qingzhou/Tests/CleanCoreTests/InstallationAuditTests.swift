#if INSTALLATION_AUDIT_STANDALONE_TESTS
import Foundation

class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value(), "断言失败", file: file, line: line)
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value(), "断言失败", file: file, line: line)
}
private func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T, file: StaticString = #file, line: UInt = #line) {
    precondition(left == right, "值不相等：\(left) / \(right)", file: file, line: line)
}
#else
import XCTest
@testable import CleanCore
#endif

final class InstallationAuditTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var app: AppRecord!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("qingzhou-audit-test-" + UUID().uuidString).standardizedFileURL
        library = root.appendingPathComponent("Library")
        let location = root.appendingPathComponent("Applications/Example.app")
        try FileManager.default.createDirectory(at: location.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        app = AppRecord(url: location, name: "Example", bundleID: "org.example.app", version: "1")
        for name in ["LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private static func xml(_ value: [String: Any]) throws -> String {
        String(data: try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), encoding: .utf8)!
    }
    @discardableResult
    private func file(_ relative: String, bytes: Data = Data("fixture".utf8)) throws -> URL {
        let path = library.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: path)
        return path
    }
    private func service(_ relative: String, label: String, program: String, associated: String? = nil) throws -> URL {
        var value: [String: Any] = ["Label": label, "ProgramArguments": [program]]
        if let associated { value["AssociatedBundleIdentifiers"] = [associated] }
        return try file(relative, bytes: PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0))
    }

    private var audit: InstallationAudit {
        var item = InstallationAudit()
        item.systemLibrary = library
        item.home = root.appendingPathComponent("Home")
        item.tool = { path, arguments in
            if path == "/usr/sbin/pkgutil" { return .init(status: 0, output: try Self.xml(["path-info": []])) }
            return .init(status: 113, output: "服务未加载")
        }
        return item
    }

    func testAssociationUsesWholeApplicationPathAndExplicitOwnership() throws {
        let first = try service("LaunchDaemons/org.example.child.plist", label: "org.example.child",
                                program: app.url.appendingPathComponent("Contents/MacOS/main").path)
        let second = try service("LaunchAgents/org.vendor.associated.plist", label: "org.vendor.associated", program: "/usr/bin/true", associated: app.bundleID)
        _ = try service("LaunchDaemons/org.example.suffix.plist", label: "org.example.suffix", program: app.url.path + "-Other/Contents/MacOS/main")
        _ = try service("LaunchDaemons/com.apple.hidden.plist", label: "com.apple.hidden", program: first.path)
        var item = audit
        item.tool = { path, arguments in
            if path == "/usr/sbin/pkgutil" { return .init(status: 0, output: try Self.xml(["path-info": []])) }
            return .init(status: 0, output: "service = {\n\tstate = running\n\tchild = {\n\t\tstate = idle\n\t}\n}")
        }
        let report = try item.inspect(app: app)
        XCTAssertEqual(Set(report.components.map { $0.url.standardizedFileURL.path }), Set([first.path, second.path]))
        XCTAssertTrue(report.components.allSatisfy { $0.state == "正在运行" })
    }

    func testMissingServiceAndUnknownStateAreDifferent() throws {
        _ = try service("LaunchDaemons/org.example.none.plist", label: "org.example.none", program: "/usr/bin/true")
        _ = try service("LaunchDaemons/org.example.denied.plist", label: "org.example.denied", program: "/usr/bin/true")
        _ = try service("LaunchDaemons/org.example.idle.plist", label: "org.example.idle", program: "/usr/bin/true")
        var item = audit
        item.tool = { _, arguments in
            if arguments.last?.hasSuffix("none") == true { return .init(status: 113, output: "") }
            if arguments.last?.hasSuffix("denied") == true { return .init(status: 1, output: "") }
            return .init(status: 0, output: "fixture {\n\tstate = waiting\n\tchild = {\n\t\tstate = running\n\t}\n}")
        }
        let state = Dictionary(uniqueKeysWithValues: try item.inspect(app: nil).components.map { ($0.url.deletingPathExtension().lastPathComponent, $0.state) })
        XCTAssertEqual(state["org.example.none"]!, "未加载")
        XCTAssertEqual(state["org.example.denied"]!, "运行状态未知")
        XCTAssertEqual(state["org.example.idle"]!, "已加载，当前未运行")
    }

    func testReceiptsKeepOnlyExistingPackageExternalFiles() throws {
        let tool = try file("Tools/helper")
        _ = try file("Tools/Other.app/Contents/main")
        _ = try file("Elsewhere")
        let appPath = app.url.path
        let libraryPath = library.path
        var item = audit
        item.tool = { _, args in
            switch args[0] {
            case "--file-info-plist":
                XCTAssertTrue(args[1] == appPath || args[1] == appPath + "/Contents/Info.plist")
                return .init(status: 0, output: try Self.xml(["path-info": [["pkgid": "org.example.package"], ["pkgid": "com.apple.package"]]]))
            case "--pkg-info-plist":
                return .init(status: 0, output: try Self.xml(["pkgid": "org.example.package", "volume": "/", "install-location": libraryPath]))
            case "--only-files":
                return .init(status: 0, output: "Tools/helper\nTools/Other.app/Contents/main\n../Outside\n/Absolute\nMissing")
            default: return .init(status: 113, output: "")
            }
        }
        let report = try item.inspect(app: app)
        XCTAssertEqual(report.receipts, ["org.example.package"])
        XCTAssertEqual(report.components.map { $0.url.standardizedFileURL.path }, [tool.path])
        XCTAssertTrue(report.components[0].evidence.contains("可能被其他程序共用"))
    }

    func testTruncatedReceiptDropsIncompleteTailAndReportsIt() throws {
        let tool = try file("helper")
        let path = library.path
        var item = audit
        item.tool = { _, args in
            switch args[0] {
            case "--file-info-plist": return .init(status: 0, output: try Self.xml(["path-info": [["pkgid": "org.example.package"]]]))
            case "--pkg-info-plist": return .init(status: 0, output: try Self.xml(["pkgid": "org.example.package", "volume": "/", "install-location": path]))
            default: return .init(status: 0, output: "helper\nmissing-fragment", truncated: true)
            }
        }
        let report = try item.inspect(app: app)
        XCTAssertEqual(report.components.map { $0.url.standardizedFileURL.path }, [tool.path])
        XCTAssertTrue(report.notes.contains { $0.contains("过长") })
    }

    func testReceiptFailuresAreReportedAndDoNotCreateCandidates() throws {
        var item = audit
        item.tool = { _, _ in .init(status: 1, output: "access denied") }
        let report = try item.inspect(app: app)
        XCTAssertEqual(report.notes.count, 2)
        XCTAssertTrue(report.components.isEmpty)
    }

    func testLinksAndProtectedHelpersAreExcluded() throws {
        let real = try file("Tools/real")
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("PrivilegedHelperTools/org.example.link"), withDestinationURL: real)
        _ = try file("PrivilegedHelperTools/cn.local.qingzhou.test")
        _ = try file("PrivilegedHelperTools/com.apple.test")
        let report = try audit.inspect(app: nil)
        XCTAssertTrue(report.components.isEmpty)
    }

    func testDeveloperUninstallerNeedsSpecificNameAndSameVerifiedTeam() throws {
        let parent = app.url.deletingLastPathComponent()
        let generic = parent.appendingPathComponent("Uninstaller.app")
        let nested = app.url.appendingPathComponent("Contents/Resources/Uninstaller.app")
        let wrongTeam = app.url.appendingPathComponent("Contents/Helpers/Example Uninstaller.app")
        let unrelated = app.url.appendingPathComponent("Contents/Resources/Other Uninstaller.app")
        for path in [generic, nested, wrongTeam, unrelated] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        var item = audit
        let targetPath = app.url.standardizedFileURL.path
        let nestedPath = nested.standardizedFileURL.path
        let wrongPath = wrongTeam.standardizedFileURL.path
        item.signature = { url in
            let path = url.standardizedFileURL.path
            return .init(identifier: path == targetPath ? "org.example.app" : (path == nestedPath ? "org.example.app.uninstaller" : "org.other.uninstaller"),
                         team: path == wrongPath ? "WRONG12345" : "ABCDE12345", groups: [])
        }
        XCTAssertEqual(item.developerUninstallers(for: app).map { $0.standardizedFileURL.path }, [nestedPath])
        item.signature = { _ in nil }
        XCTAssertTrue(item.developerUninstallers(for: app).isEmpty)
    }

    func testRemovedApplicationUsesOriginalPathForReceiptLookup() throws {
        var item = audit
        let original = app.url
        let location = root.appendingPathComponent("Trash/Example.app")
        let removed = AppRecord(url: location, name: app.name, bundleID: app.bundleID, version: "1")
        let expected = Set([original.path, original.appendingPathComponent("Contents/Info.plist").path])
        item.tool = { path, args in
            if path == "/usr/sbin/pkgutil" { XCTAssertTrue(expected.contains(args[1])) }
            return .init(status: 0, output: try Self.xml(["path-info": []]))
        }
        let report = try item.inspect(app: removed, originalURL: original)
        XCTAssertTrue(report.receipts.isEmpty)
        XCTAssertTrue(report.uninstallers.isEmpty)
    }
}

#if INSTALLATION_AUDIT_STANDALONE_TESTS
@main struct InstallationAuditRunner {
    static func main() throws {
        let tests: [(String, (InstallationAuditTests) -> () throws -> Void)] = [
            ("配置归属按完整应用路径及显式声明核对", InstallationAuditTests.testAssociationUsesWholeApplicationPathAndExplicitOwnership),
            ("未加载、正在运行和状态未知分别显示", InstallationAuditTests.testMissingServiceAndUnknownStateAreDifferent),
            ("安装收据只显示当前存在的包外文件", InstallationAuditTests.testReceiptsKeepOnlyExistingPackageExternalFiles),
            ("超长收据保留明确提示并跳过不完整末行", InstallationAuditTests.testTruncatedReceiptDropsIncompleteTailAndReportsIt),
            ("系统拒绝查询时显示失败位置", InstallationAuditTests.testReceiptFailuresAreReportedAndDoNotCreateCandidates),
            ("保留链接、系统及清舟后台组件", InstallationAuditTests.testLinksAndProtectedHelpersAreExcluded),
            ("开发者卸载入口核对用途名称和签名团队", InstallationAuditTests.testDeveloperUninstallerNeedsSpecificNameAndSameVerifiedTeam),
            ("已移走应用按原始路径核对收据", InstallationAuditTests.testRemovedApplicationUsesOriginalPathForReceiptLookup)
        ]
        for (name, run) in tests {
            let test = InstallationAuditTests()
            try test.setUpWithError()
            do { try run(test)(); try test.tearDownWithError() } catch { try? test.tearDownWithError(); throw error }
            print("通过：" + name)
        }
        print("安装收据与后台组件：\(tests.count) 项检查通过")
    }
}
#endif
