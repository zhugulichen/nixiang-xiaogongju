#if LOCATION_STANDALONE_TESTS
import Foundation
private enum LocationAssertionError: Error { case missingValue }
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
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "值不相等：\(lhs) / \(rhs)", file: file, line: line)
}
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression(); preconditionFailure("本应拒绝", file: file, line: line) } catch {}
}
#else
import XCTest
@testable import CleanCore
#endif

final class ApplicationLocationTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var service: ApplicationLocationService { ApplicationLocationService(home: home) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("QingzhouLocationTests-" + UUID().uuidString)
        home = root.appendingPathComponent("Home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func application(_ relative: String, identifier: String = "org.example.dropped") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let metadata: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "拖放测试", "CFBundleVersion": "42"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testReadApplicationMetadataWithoutExpandingScope() throws {
        let url = try application("Outside/Example.app")
        let app = try service.application(at: url)
        XCTAssertEqual(app.bundleID, "org.example.dropped")
        XCTAssertEqual(app.version, "42")
        XCTAssertFalse(app.isProtected)
        XCTAssertFalse(ApplicationLocationService.applicationIsInScope(url, roots: [root.appendingPathComponent("Applications")]))
    }

    func testScopeUsesComponentBoundaries() throws {
        let apps = root.appendingPathComponent("Applications")
        XCTAssertTrue(ApplicationLocationService.applicationIsInScope(apps.appendingPathComponent("Utilities/Example.app"), roots: [apps]))
        XCTAssertFalse(ApplicationLocationService.applicationIsInScope(root.appendingPathComponent("ApplicationsElsewhere/Example.app"), roots: [apps]))
        XCTAssertFalse(ApplicationLocationService.applicationIsInScope(apps, roots: [apps]))
    }

    func testRejectsRemoteFilesAndOrdinaryDirectories() throws {
        XCTAssertThrowsError(try service.application(at: URL(string: "https://example.com/Example.app")!))
        XCTAssertThrowsError(try service.application(at: URL(string: "file://remote.example/Example.app")!))
        XCTAssertThrowsError(try service.application(at: home))
        let fake = root.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.application(at: fake))
    }

    func testRejectsTrashApplicationsAndRoots() throws {
        let app = try application("Home/.Trash/Example.app")
        XCTAssertThrowsError(try service.application(at: app))
        XCTAssertThrowsError(try service.scanRoot(at: app.deletingLastPathComponent()))
        let external = try application("External/.Trashes/501/Example.app")
        XCTAssertThrowsError(try service.application(at: external))
    }

    func testRejectsNestedApplicationsAndDirectories() throws {
        let nested = try application("Parent.app/Contents/Helpers/Inner.app")
        XCTAssertThrowsError(try service.application(at: nested))
        XCTAssertThrowsError(try service.scanRoot(at: nested.deletingLastPathComponent()))
    }

    func testRejectsDirectAndAncestorSymbolicLinks() throws {
        let app = try application("Original/Example.app")
        let link = root.appendingPathComponent("Shortcut.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertThrowsError(try service.application(at: link))
        let parentLink = root.appendingPathComponent("ParentLink")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: app.deletingLastPathComponent())
        XCTAssertThrowsError(try service.application(at: parentLink.appendingPathComponent("Example.app")))
        XCTAssertThrowsError(try service.scanRoot(at: parentLink))
    }

    func testPreservesSystemAndOwnApplicationProtection() throws {
        let own = try application("Own.app", identifier: "cn.local.qingzhou")
        let system = try application("System.app", identifier: "com.apple.testapp")
        let ownRecord = try service.application(at: own)
        let systemRecord = try service.application(at: system)
        XCTAssertTrue(ownRecord.isProtected)
        XCTAssertTrue(systemRecord.isProtected)
    }

    func testAcceptsWrappedApplications() throws {
        let inner = try application("Wrapped.app/Wrapper/Mobile.app", identifier: "org.example.mobile")
        let outer = root.appendingPathComponent("Wrapped.app")
        try FileManager.default.createSymbolicLink(at: outer.appendingPathComponent("WrappedBundle"), withDestinationURL: inner)
        XCTAssertEqual(try service.application(at: outer).bundleID, "org.example.mobile")
    }

    func testRejectsOverlyBroadAndLibraryRoots() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Applications"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.scanRoot(at: home))
        XCTAssertThrowsError(try service.scanRoot(at: URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try service.scanRoot(at: URL(fileURLWithPath: "/System/Applications")))
        XCTAssertThrowsError(try service.scanRoot(at: home.appendingPathComponent("Library")))
        XCTAssertThrowsError(try service.scanRoot(at: home.appendingPathComponent("Library/Applications")))
        let app = try application("Applications/Example.app")
        XCTAssertThrowsError(try service.scanRoot(at: app))
    }

    func testAcceptsDedicatedFolderWithUnicodeAndSpaces() throws {
        let app = try application("Home/我的应用 软件/Example.app")
        XCTAssertEqual(try service.scanRoot(at: app.deletingLastPathComponent()).path, app.deletingLastPathComponent().path)
        XCTAssertEqual(try service.application(at: app).url.path, app.path)
    }

    func testRejectsMountedVolumeRoots() throws {
        // Avoid probing special system automount points such as /home during tests.
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .filter { $0.path == "/" || $0.path.hasPrefix("/Volumes/") }
        XCTAssertFalse(volumes.isEmpty)
        for volume in volumes { XCTAssertThrowsError(try service.scanRoot(at: volume)) }
    }
}

#if LOCATION_STANDALONE_TESTS
@main
struct LocationTestRunner {
    static func main() throws {
        setbuf(stdout, nil)
        let tests: [(String, (ApplicationLocationTests) -> () throws -> Void)] = [
            ("拖入读取元数据且不扩展范围", ApplicationLocationTests.testReadApplicationMetadataWithoutExpandingScope),
            ("扫描范围按路径边界判断", ApplicationLocationTests.testScopeUsesComponentBoundaries),
            ("拒绝远程地址和普通目录", ApplicationLocationTests.testRejectsRemoteFilesAndOrdinaryDirectories),
            ("拒绝废纸篓内的应用及目录", ApplicationLocationTests.testRejectsTrashApplicationsAndRoots),
            ("拒绝应用内部组件及目录", ApplicationLocationTests.testRejectsNestedApplicationsAndDirectories),
            ("拒绝直接及祖先符号链接", ApplicationLocationTests.testRejectsDirectAndAncestorSymbolicLinks),
            ("保留系统与清舟自身保护", ApplicationLocationTests.testPreservesSystemAndOwnApplicationProtection),
            ("识别手机移植包装应用", ApplicationLocationTests.testAcceptsWrappedApplications),
            ("拒绝过宽根目录与资源库", ApplicationLocationTests.testRejectsOverlyBroadAndLibraryRoots),
            ("兼容中文与空格目录", ApplicationLocationTests.testAcceptsDedicatedFolderWithUnicodeAndSpaces),
            ("拒绝已挂载磁盘根目录", ApplicationLocationTests.testRejectsMountedVolumeRoots)
        ]
        for (name, run) in tests {
            let test = ApplicationLocationTests()
            try test.setUpWithError()
            do { try run(test)(); try test.tearDownWithError() }
            catch { try? test.tearDownWithError(); throw error }
            print("通过：\(name)")
        }
        print("应用拖放与扫描目录测试：\(tests.count) 项通过，0 项失败")
    }
}
#endif
