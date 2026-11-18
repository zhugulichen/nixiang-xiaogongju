#if TRASH_STANDALONE_TESTS
import Foundation

private enum TrashAssertionError: Error { case missingValue }
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(value(), "断言失败：" + message, file: file, line: line)
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value(), "断言失败", file: file, line: line)
}
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "值不相等：\(lhs) / \(rhs)", file: file, line: line)
}
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression(); preconditionFailure("预期拒绝操作：" + message, file: file, line: line) } catch {}
}
private func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { preconditionFailure("不应出现错误：\(error)", file: file, line: line) }
}
private func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value != nil, "预期非空值", file: file, line: line)
}
private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TrashAssertionError.missingValue }
    return value
}
#else
import XCTest
@testable import CleanCore
#endif

final class TrashServiceTests: XCTestCase {
    var root: URL!
    var service: TrashService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        service = TrashService(home: root, applicationRoots: [root.appendingPathComponent("Applications")], historyURL: root.appendingPathComponent("history.json"), testTrashDirectory: root.appendingPathComponent("Trash"))
        service.runningApplications = { [] }
        service.directRecycle = { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        service.finderRecycle = { _ in throw CleanError.refused("测试禁止调用真实访达") }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func fixture(_ name: String = "org.example.demo") throws -> CleanFile {
        let url = root.appendingPathComponent("Library/Caches/" + name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: url.appendingPathComponent("data"))
        return CleanFile(url: url, kind: .cache, reason: "测试")
    }

    func testRestoreOneEntryLeavesOtherInTrash() throws {
        let first = try fixture("org.example.one"), second = try fixture("org.example.two")
        let batch = try service.moveToTrash([first, second])
        XCTAssertEqual(try service.restore(batchID: batch.id, entryIDs: []), 0)
        XCTAssertEqual(try service.restore(batchID: batch.id, entryIDs: [second.id]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(try service.restore(batchID: batch.id, entryIDs: [second.id]), 0)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
    }

    func testInstallerDiscoveryAndRoundTrip() throws {
        let folder = root.appendingPathComponent("Downloads/归档")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Test.pkg")
        let payload = Data("xar!".utf8) + Data(repeating: 0, count: 24)
        try payload.write(to: package)
        try Data("a document".utf8).write(to: folder.appendingPathComponent("Fake.pkg"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Link.pkg"), withDestinationURL: package)
        let image = folder.appendingPathComponent("Test.dmg")
        try (Data("koly".utf8) + Data(repeating: 0, count: 508)).write(to: image)
        var reader = InstallerFiles(home: root)
        reader.mountedImages = { [image.standardizedFileURL.path] }
        let files = reader.scan().files
        XCTAssertEqual(Set(files.map { $0.url.lastPathComponent }), ["Test.pkg", "Test.dmg"])
        XCTAssertTrue(files.allSatisfy { !$0.defaultSelected })
        XCTAssertEqual(files.first { $0.url.lastPathComponent == "Test.dmg" }?.risk, .protected)
        let selected = try XCTUnwrap(files.first { $0.url.lastPathComponent == "Test.pkg" })
        let batch = try service.moveToTrash([selected], reviewed: service.review([selected]))
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertEqual(try service.restore(batchID: batch.id, entryIDs: [try XCTUnwrap(batch.entries.first).id]), 1)
        XCTAssertEqual(try Data(contentsOf: package), payload)
        let outside = root.appendingPathComponent("Outside.pkg")
        try payload.write(to: outside)
        XCTAssertThrowsError(try service.review([CleanFile(url: outside, kind: .installer, reason: "测试")]))
        XCTAssertThrowsError(try service.review([CleanFile(url: folder.appendingPathComponent("Fake.pkg"), kind: .installer, reason: "测试")]))
        XCTAssertThrowsError(try service.review([CleanFile(url: package, kind: .cache, reason: "测试")]))
    }

    func protectedService(_ records: [SkippedApplication]) -> TrashService {
        let restricted = TrashService(home: root, applicationRoots: [root.appendingPathComponent("Applications")],
            historyURL: root.appendingPathComponent("history.json"), testTrashDirectory: root.appendingPathComponent("Trash"),
            protection: ApplicationProtectionPolicy(records: records))
        restricted.runningApplications = { [] }
        restricted.systemRecycle = { _ in preconditionFailure("受保护文件不能调用系统回收") }
        restricted.directRecycle = { _ in preconditionFailure("受保护文件不能调用本进程回收") }
        restricted.finderRecycle = { _ in preconditionFailure("受保护文件不能调用访达") }
        return restricted
    }

    func testSkipListStopsEveryRecycleMethodAndOtherCopies() throws {
        let app = try applicationFixture()
        let copy = try applicationFixture("Other Copy")
        let restricted = protectedService([SkippedApplication(bundleID: "org.example.fixture", name: "示例")])
        let forged = CleanFile(url: copy.url, kind: .application, reason: "无归属元数据")
        for method in [TrashMoveMethod.direct, .systemInteractive, .finderInteractive, .systemWithFinderFallback] {
            XCTAssertThrowsError(try restricted.moveToTrash([app], method: method))
            XCTAssertThrowsError(try restricted.moveToTrash([forged], method: method))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.url.path))
    }

    func testSkipListProtectsHelperDataAndSharedParent() throws {
        let file = try fixture("org.example.helper")
        let child = file.url.appendingPathComponent("data")
        let restricted = protectedService([SkippedApplication(bundleID: "org.example.owner", name: "示例",
            relatedIdentifiers: ["org.example.helper"], paths: [child])])
        XCTAssertThrowsError(try restricted.moveToTrash([file], method: .systemInteractive))
        let owned = CleanFile(url: file.url, kind: .cache, reason: "辅助数据", ownerBundleID: "org.example.helper")
        XCTAssertThrowsError(try restricted.moveToTrash([owned]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }

    func testNewProtectionAfterPreviewStopsExecution() throws {
        let file = try fixture()
        XCTAssertNoThrow(try service.validate(file, method: .systemInteractive))
        let restricted = protectedService([SkippedApplication(bundleID: "org.example.demo", name: "示例", paths: [file.url])])
        XCTAssertThrowsError(try restricted.moveToTrash([file], method: .systemInteractive))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testSkipListDoesNotBlockRecovery() throws {
        let app = try applicationFixture()
        let batch = try service.moveToTrash([app])
        let restricted = protectedService([SkippedApplication(bundleID: "org.example.fixture", name: "示例", paths: [app.url])])
        XCTAssertEqual(try restricted.restore(batchID: batch.id), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testFinderRecycleRoundTripUsesValidatedMapping() throws {
        let app = try applicationFixture()
        service.systemRecycle = { _ in preconditionFailure("访达模式不能调用其他回收方式") }
        service.directRecycle = { _ in preconditionFailure("访达模式不能调用其他回收方式") }
        service.finderRecycle = { source in
            let target = self.root.appendingPathComponent("Trash/Example.app")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
        let batch = try service.moveToTrash([app], method: .finderInteractive)
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testFinderModeRefusesDataBeforeAnyMove() throws {
        let app = try applicationFixture()
        let cache = try fixture()
        service.finderRecycle = { _ in preconditionFailure("应在整体预检拒绝") }
        XCTAssertThrowsError(try service.moveToTrash([app, cache], method: .finderInteractive))
        let disguised = CleanFile(url: cache.url, kind: .application, reason: "伪装成应用的缓存")
        XCTAssertThrowsError(try service.moveToTrash([disguised], method: .finderInteractive))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url.path))
    }

    func testFinderCancellationStopsLaterApplications() throws {
        let first = try applicationFixture("First", owner: "org.example.first")
        let second = try applicationFixture("Second", owner: "org.example.second")
        var calls = 0
        service.finderRecycle = { _ in calls += 1; throw NSError(domain: NSOSStatusErrorDomain, code: -128) }
        let batch = try service.moveToTrash([first, second], method: .finderInteractive)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(batch.entries.first?.failure?.category, .cancelled)
        XCTAssertEqual(batch.successCount, 0)
    }

    func testFinderAutomationDenialIsSpecific() throws {
        let app = try applicationFixture()
        service.finderRecycle = { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1743) }
        let batch = try service.moveToTrash([app], method: .finderInteractive)
        XCTAssertEqual(batch.entries.first?.failure?.category, .automation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testFinderRejectsWrongTrashIdentity() throws {
        let app = try applicationFixture()
        let wrong = try fixture("org.example.wrong")
        service.finderRecycle = { _ in
            let target = self.root.appendingPathComponent("Trash/Wrong.app")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: wrong.url, to: target)
            return target
        }
        let batch = try service.moveToTrash([app], method: .finderInteractive)
        XCTAssertEqual(batch.successCount, 0)
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testFinderArgumentsRemainLiteral() throws {
        let value = "/Applications/测试\"\\\nend tell.app"
        let event = FinderRecycleBridge.event(path: value)
        XCTAssertEqual(event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.atIndex(1)?.stringValue, value)
        // Exercise the same event with a local handler that never contacts another app.
        let echo = try XCTUnwrap(NSAppleScript(source: "on recyclePath(inputPath)\nreturn inputPath\nend recyclePath"))
        var details: NSDictionary?
        XCTAssertEqual(echo.executeAppleEvent(event, error: &details).stringValue, value)
        XCTAssertTrue(details == nil)
        XCTAssertThrowsError(try FinderRecycleBridge.destination("https://example.com/Example.app"))
        XCTAssertThrowsError(try FinderRecycleBridge.destination("file://other-host/Example.app"))
        XCTAssertEqual(try FinderRecycleBridge.destination("file:///Users/example/.Trash/Example.app").path,
                       "/Users/example/.Trash/Example.app")
    }
    func testRoundTripPreservesContent() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }
    func testAdditionalValidationStopsLaterMoves() throws {
        let first = try fixture("org.example.one")
        let second = try fixture("org.example.two")
        var checks = 0
        let batch = try service.moveToTrash([first, second], additionalValidation: {
            checks += 1
            if checks > 3 { throw CleanError.refused("候选被恢复，停止清理") }
        })
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertNotNil(batch.entries.last?.error)
    }
    func testAppScriptDirectoryRoundtripAndOwnershipBoundaries() throws {
        let parent = root.appendingPathComponent("Library/Application Scripts")
        let identifier = "org.example.scriptable"
        func script(_ name: String, owner: String?) -> CleanFile {
            CleanFile(url: parent.appendingPathComponent(name), kind: .support, reason: "自建脚本", risk: .personal, ownerBundleID: owner)
        }
        let file = script(identifier, owner: identifier)
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        let text = file.url.appendingPathComponent("fixture.txt")
        try Data("test script".utf8).write(to: text)
        XCTAssertThrowsError(try service.validate(script(identifier, owner: "org.example.other")))
        for id in ["group.org.example.suite", "ABCD123456.shared", "com.apple.example"] {
            let folder = script(id, owner: id)
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            XCTAssertThrowsError(try service.validate(folder))
        }
        let regular = script("org.example.file", owner: "org.example.file")
        try Data().write(to: regular.url)
        XCTAssertThrowsError(try service.validate(regular))
        let batch = try service.moveToTrash([file])
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "test script")
    }

    func testBrowserChannelOnlyAllowsExactMappedDirectory() throws {
        let vendor = root.appendingPathComponent("Library/Application Support/Google")
        let url = vendor.appendingPathComponent("Chrome Dev")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        func entry(_ path: URL, _ owner: String) -> CleanFile {
            CleanFile(url: path, kind: .support, reason: "自建渠道目录", ownerBundleID: owner)
        }
        XCTAssertThrowsError(try service.validate(entry(url, "com.google.Chrome")))
        XCTAssertThrowsError(try service.validate(entry(vendor, "com.google.Chrome.dev")))
        let batch = try service.moveToTrash([entry(url, "com.google.Chrome.dev")])
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
    }

    func testRejectsRootsAndOutOfBounds() throws {
        for url in [root!, root.appendingPathComponent("Library/Caches"), URL(fileURLWithPath: "/System/Applications/Safari.app")] {
            XCTAssertThrowsError(try service.validate(CleanFile(url: url, kind: .cache, reason: "测试")))
        }
    }
    func testSymbolicLinkCannotEscape() throws {
        let outside = root.appendingPathComponent("Private")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Library/Caches/org.example.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try service.validate(CleanFile(url: link, kind: .cache, reason: "测试")))
    }
    func testBatchPreflightPreventsPartialMutation() throws {
        let file = try fixture()
        XCTAssertThrowsError(try service.moveToTrash([file, CleanFile(url: root, kind: .cache, reason: "测试")]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
    func testRestoreDoesNotOverwrite() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        _ = try fixture()
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        XCTAssertNotNil(service.history().first?.entries.first?.error)
    }
    func testDeduplicatesNestedSelections() throws {
        let file = try fixture()
        let child = CleanFile(url: file.url.appendingPathComponent("data"), kind: .cache, reason: "测试")
        XCTAssertEqual(service.normalized([file, child, file]).count, 1)
    }
    func testProtectsAppleAndOwnData() throws {
        let file = try fixture("com.apple.system")
        XCTAssertThrowsError(try service.validate(CleanFile(url: file.url, kind: .cache, reason: "测试", ownerBundleID: "com.apple.system")))
        let own = try fixture("cn.local.qingzhou")
        XCTAssertThrowsError(try service.validate(own))
    }

    func testWrappedApplicationCanRoundTrip() throws {
        let app = root.appendingPathComponent("Applications/Wrapped.app")
        let inner = app.appendingPathComponent("Wrapper/Phone.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "org.example.phone", "CFBundleName": "Phone"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: inner.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Phone.app")
        let file = CleanFile(url: app, kind: .application, reason: "包装应用测试", ownerBundleID: "org.example.phone")
        let batch = try service.moveToTrash([file])
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertEqual(ApplicationMetadata.information(at: app)?["CFBundleIdentifier"] as? String, "org.example.phone")
    }

    func testWrappedApplicationCannotBorrowExternalIdentity() throws {
        let app = root.appendingPathComponent("Applications/Fake.app")
        let outside = root.appendingPathComponent("Outside.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "org.example.external"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: outside.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("WrappedBundle"), withDestinationURL: outside)
        XCTAssertTrue(ApplicationMetadata.information(at: app) == nil)
        XCTAssertThrowsError(try service.validate(CleanFile(url: app, kind: .application, reason: "测试")))
    }

    func writeJournal(_ entries: [TrashEntry]) throws -> UUID {
        let id = UUID()
        let batch = TrashBatch(id: id, date: Date(), entries: entries)
        try JSONEncoder().encode([batch]).write(to: root.appendingPathComponent("history.json"))
        return id
    }

    func testRejectsForgedRestoreSourceOutsideTrash() throws {
        let unrelated = root.appendingPathComponent("private-document.txt")
        try Data("keep".utf8).write(to: unrelated)
        let destination = root.appendingPathComponent("Library/Caches/org.example.forged")
        let id = try writeJournal([TrashEntry(originalURL: destination, trashURL: unrelated, error: nil, restored: false)])
        XCTAssertEqual(try service.restore(batchID: id), 0)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsForgedRestoreDestinationOutsideAllowedRoots() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        let source = try XCTUnwrap(batch.entries.first?.trashURL)
        let destination = root.appendingPathComponent("private-document.txt")
        let id = try writeJournal([TrashEntry(originalURL: destination, trashURL: source, error: nil, restored: false)])
        XCTAssertEqual(try service.restore(batchID: id), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestoreRejectsSymbolicLinkSourceAndChangedParent() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        let source = try XCTUnwrap(batch.entries.first?.trashURL)
        let outside = root.appendingPathComponent("private-data")
        try FileManager.default.moveItem(at: source, to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: outside, to: source)
        let caches = root.appendingPathComponent("Library/Caches")
        let replacement = root.appendingPathComponent("replacement")
        try FileManager.default.moveItem(at: caches, to: replacement)
        try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: replacement)
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.appendingPathComponent(file.url.lastPathComponent).path))
    }

    func testRestoreDoesNotReplaceDanglingSymlink() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.url.path), root.appendingPathComponent("missing").path)
    }

    func testProtectsSystemNamesWithoutOwnerMetadata() throws {
        for name in ["com.apple.finder", "group.com.apple.cloud", "ABCD.com.apple.shared", ".GlobalPreferences.plist", "Qingzhou", "cn.local.qingzhou.settings"] {
            let file = try fixture(name)
            XCTAssertThrowsError(try service.validate(file), name)
        }
    }

    func testInferredRunningOwnerBlocksUnlabelledCache() throws {
        let file = try fixture("org.example.running.cache")
        service.runningApplications = { [.init(bundleID: "org.example.running", url: nil, name: "运行中的应用")] }
        XCTAssertThrowsError(try service.validate(file))
        XCTAssertNoThrow(try service.validate(file, checkRunning: false))
    }

    func testRunningNestedAppBlocksParentRemoval() throws {
        let application = root.appendingPathComponent("Applications/Test.app")
        let contents = application.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.test", "CFBundleName": "Test"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let file = CleanFile(url: application, kind: .application, reason: "测试")
        service.runningApplications = { [.init(bundleID: "org.example.helper", url: application.appendingPathComponent("Contents/Helper.app"), name: "辅助进程")] }
        XCTAssertThrowsError(try service.validate(file))
    }

    func testNestedApplicationCannotBeRemovedSeparately() throws {
        let nested = root.appendingPathComponent("Applications/Outer.app/Contents/Helper.app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.validate(CleanFile(url: nested, kind: .application, reason: "测试")))
    }

    func testJournalFailureBeforeMoveLeavesFileUntouched() throws {
        let file = try fixture()
        service.beforeJournalWrite = { throw CleanError.refused("模拟磁盘写入失败") }
        XCTAssertThrowsError(try service.moveToTrash([file]))
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testJournalFailureAfterMoveRollsBackCurrentFile() throws {
        let file = try fixture()
        var writes = 0
        service.beforeJournalWrite = { writes += 1; if writes == 2 { throw CleanError.refused("模拟磁盘写入失败") } }
        XCTAssertThrowsError(try service.moveToTrash([file]))
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "test")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Trash").path).count, 0)
    }

    func testRestoreJournalFailureRollsBackToTrash() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        let source = try XCTUnwrap(batch.entries.first?.trashURL)
        var writes = 0
        service.beforeJournalWrite = { writes += 1; if writes == 2 { throw CleanError.refused("模拟磁盘写入失败") } }
        XCTAssertThrowsError(try service.restore(batchID: batch.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testMalformedJournalPreventsAnyMove() throws {
        let file = try fixture()
        try Data("broken journal".utf8).write(to: root.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try service.moveToTrash([file]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testNormalizationUsesPathComponentsAndStandardizedURLs() throws {
        let file = try fixture()
        let sibling = try fixture("org.example.demo-extra")
        let duplicate = CleanFile(url: file.url.appendingPathComponent("../org.example.demo"), kind: .cache, reason: "测试")
        let child = CleanFile(url: file.url.appendingPathComponent("folder/../data"), kind: .cache, reason: "测试")
        XCTAssertEqual(service.normalized([file, sibling, duplicate, child]).count, 2)
    }

    func testRejectsNonFileURLs() throws {
        let remote = URL(string: "https://example.com" + root.appendingPathComponent("Library/Caches/org.example.demo").path)!
        XCTAssertThrowsError(try service.validate(CleanFile(url: remote, kind: .cache, reason: "测试")))
    }

    func testRunningNamedCacheAndRestoreOwnerAreProtected() throws {
        let file = try fixture("Friendly App")
        service.runningApplications = { [.init(bundleID: "org.example.friendly", url: nil, name: "Friendly App")] }
        XCTAssertThrowsError(try service.validate(file))
        service.runningApplications = { [] }
        let owned = CleanFile(url: file.url, kind: .cache, reason: "测试", ownerBundleID: "org.example.other")
        let batch = try service.moveToTrash([owned])
        service.runningApplications = { [.init(bundleID: "org.example.other", url: nil, name: "Different Name")] }
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        let source = try XCTUnwrap(batch.entries.first?.trashURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testLoadedOrUnknownLaunchAgentCannotBeRemoved() throws {
        let path = root.appendingPathComponent("Library/LaunchAgents/org.example.agent.plist")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "org.example.agent", "Program": "/usr/bin/true"], format: .xml, options: 0).write(to: path)
        let file = CleanFile(url: path, kind: .launchAgent, reason: "测试")
        service.launchAgentLoaded = { _ in true }
        XCTAssertThrowsError(try service.validate(file))
        service.launchAgentLoaded = { _ in nil }
        XCTAssertThrowsError(try service.validate(file))
        service.launchAgentLoaded = { _ in false }
        XCTAssertNoThrow(try service.validate(file))
    }
    func testExactBrowserSubdirectoryCanRoundTripButVendorCannot() throws {
        let path = root.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("browser data".utf8).write(to: path.appendingPathComponent("data"))
        let file = CleanFile(url: path, kind: .support, reason: "测试", risk: .personal, ownerBundleID: "com.google.Chrome")
        XCTAssertNoThrow(try service.validate(file))
        XCTAssertThrowsError(try service.validate(CleanFile(url: path, kind: .support, reason: "测试", ownerBundleID: "com.other.app")))
        XCTAssertThrowsError(try service.validate(CleanFile(url: path.deletingLastPathComponent(), kind: .support, reason: "测试", ownerBundleID: "com.google.Chrome")))
        let batch = try service.moveToTrash([file])
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("data"), encoding: .utf8), "browser data")
    }

    func testByHostAllowsOnlyExactOwnerAndUUID() throws {
        let parent = root.appendingPathComponent("Library/Preferences/ByHost")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent("org.example.host.550E8400-E29B-41D4-A716-446655440000.plist")
        try Data("settings".utf8).write(to: path)
        let file = CleanFile(url: path, kind: .preference, reason: "测试", ownerBundleID: "org.example.host")
        XCTAssertNoThrow(try service.validate(file))
        XCTAssertThrowsError(try service.validate(CleanFile(url: path, kind: .preference, reason: "测试", ownerBundleID: "org.example")))
        XCTAssertThrowsError(try service.validate(CleanFile(url: parent, kind: .preference, reason: "测试", ownerBundleID: "org.example.host")))
        let invalid = parent.appendingPathComponent("org.example.host.not-a-uuid.plist")
        try Data().write(to: invalid)
        XCTAssertThrowsError(try service.validate(CleanFile(url: invalid, kind: .preference, reason: "测试", ownerBundleID: "org.example.host")))
    }

    func testSymbolicJournalCannotRedirectWrites() throws {
        let file = try fixture()
        let outside = root.appendingPathComponent("important.json")
        try Data("keep original".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("history.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try service.moveToTrash([file]))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }


    func applicationFixture(_ name: String = "Example", owner: String = "org.example.fixture") throws -> CleanFile {
        let url = root.appendingPathComponent("Applications/" + name + ".app")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": owner], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return CleanFile(url: url, kind: .application, reason: "交互回收测试", ownerBundleID: owner)
    }

    func installMockRecycle() {
        service.systemRecycle = { url in
            let trash = self.root.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return TrashService.RecycleReply(destinations: [url: destination], error: nil)
        }
    }

    func testSystemRecycleDenialPreservesApplicationDiagnostic() throws {
        let app = try applicationFixture()
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        service.systemRecycle = { _ in
            TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSUnderlyingErrorKey: underlying]))
        }
        let batch = try service.moveToTrash([app], method: .systemInteractive)
        let failure = try XCTUnwrap(batch.entries.first?.failure)
        XCTAssertEqual(batch.successCount, 0)
        XCTAssertEqual(failure.category, .applicationManagement)
        XCTAssertEqual(failure.stage, .move)
        XCTAssertEqual(failure.path, app.url.path)
        XCTAssertEqual(failure.systemCodes.count, 3)
        XCTAssertTrue(failure.systemCodes.contains { $0.contains("系统交互回收") && $0.contains(NSPOSIXErrorDomain) })
        XCTAssertTrue(failure.systemCodes.contains { $0.contains("本进程回收") && $0.contains(NSCocoaErrorDomain) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertEqual(service.history().first?.entries.first?.failure?.category, .applicationManagement)
    }

    func testSystemRecycleDenialDistinguishesContainerAndFile() throws {
        let container = root.appendingPathComponent("Library/Containers/org.example.container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let cache = try fixture()
        service.systemRecycle = { _ in TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) }
        let files = [CleanFile(url: container, kind: .container, reason: "容器测试", ownerBundleID: "org.example.container"), cache]
        let batch = try service.moveToTrash(files, method: .systemInteractive)
        XCTAssertEqual(batch.entries.first { $0.originalURL.path == container.path }?.failure?.category, .appData)
        XCTAssertEqual(batch.entries.first { $0.originalURL.path == cache.url.path }?.failure?.category, .fileAccess)
        XCTAssertEqual(batch.successCount, 0)
    }

    func testSystemRecycleCancellationStopsFollowingItems() throws {
        let first = try fixture("org.example.first"), second = try fixture("org.example.second")
        var calls = 0
        service.systemRecycle = { _ in
            calls += 1
            return TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        let batch = try service.moveToTrash([first, second], method: .systemInteractive)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(batch.entries.first?.failure?.category, .cancelled)
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testApplicationRefusalKeepsOwnedData() throws {
        let app = try applicationFixture()
        let cache = try fixture("org.example.fixture")
        let owned = CleanFile(url: cache.url, kind: .cache, reason: "属于测试应用", ownerBundleID: app.ownerBundleID)
        var calls: [URL] = []
        service.systemRecycle = { url in
            calls.append(url)
            return TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }
        let batch = try service.moveToTrash([owned, app], method: .systemInteractive)
        XCTAssertEqual(calls.map(\.path), [app.url.path])
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path))
    }

    func testApplicationRefusalWithoutOwnerMetadataKeepsOwnedData() throws {
        let app = try applicationFixture()
        let unlabelled = CleanFile(url: app.url, kind: .application, reason: "旧调用没有归属标识")
        let cache = try fixture("org.example.fixture")
        let owned = CleanFile(url: cache.url, kind: .cache, reason: "属于测试应用", ownerBundleID: "org.example.fixture")
        var calls = 0
        service.systemRecycle = { _ in
            calls += 1
            return TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }
        let batch = try service.moveToTrash([owned, unlabelled], method: .systemInteractive)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path))
    }

    func testSuccessfulSystemMappingWithErrorRemainsRecoverable() throws {
        let file = try fixture()
        installMockRecycle()
        let move = service.systemRecycle
        service.systemRecycle = { url in
            let result = try move(url)
            return TrashService.RecycleReply(destinations: result.destinations, error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }
        let batch = try service.moveToTrash([file], method: .systemInteractive)
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertTrue(batch.entries.first?.error == nil)
        XCTAssertNotNil(service.history().first?.entries.first?.trashURL)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testSuccessfulMappingWithCancellationStopsFollowingItems() throws {
        let first = try fixture("org.example.first"), second = try fixture("org.example.second")
        installMockRecycle()
        let move = service.systemRecycle
        var calls = 0
        service.systemRecycle = { url in
            calls += 1
            let result = try move(url)
            return TrashService.RecycleReply(destinations: result.destinations, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        let batch = try service.moveToTrash([first, second], method: .systemInteractive)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
    }

    func testInvalidSystemMappingRetainsLocationWithoutRestoringWrongIdentity() throws {
        let file = try fixture()
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let reported = trash.appendingPathComponent("reported")
        try Data("unrelated".utf8).write(to: reported)
        service.systemRecycle = { url in TrashService.RecycleReply(destinations: [url: reported], error: nil) }
        let batch = try service.moveToTrash([file], method: .systemInteractive)
        XCTAssertEqual(batch.successCount, 0)
        XCTAssertEqual(batch.entries.first?.trashURL?.path, reported.path)
        XCTAssertNotNil(batch.entries.first?.error)
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        XCTAssertEqual(try String(contentsOf: reported, encoding: .utf8), "unrelated")
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testSystemRecycleMappingMustBelongToRequestedItemAndTrash() throws {
        let file = try fixture()
        let arbitrary = root.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: arbitrary)
        service.systemRecycle = { url in TrashService.RecycleReply(destinations: [url: arbitrary], error: nil) }
        let invalidLocation = try service.moveToTrash([file], method: .systemInteractive)
        XCTAssertEqual(invalidLocation.successCount, 0)
        XCTAssertEqual(invalidLocation.entries.first?.trashURL?.path, arbitrary.path)
        service.systemRecycle = { _ in TrashService.RecycleReply(destinations: [arbitrary: arbitrary], error: nil) }
        let invalidKey = try service.moveToTrash([file], method: .systemInteractive)
        XCTAssertEqual(invalidKey.successCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try String(contentsOf: arbitrary, encoding: .utf8), "keep")
    }

    func testRestoreRejectsChangedTrashIdentity() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        let source = try XCTUnwrap(batch.entries.first?.trashURL)
        let original = source.deletingLastPathComponent().appendingPathComponent("original")
        try FileManager.default.moveItem(at: source, to: original)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("different".utf8).write(to: source.appendingPathComponent("data"))
        XCTAssertEqual(try service.restore(batchID: batch.id), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("data"), encoding: .utf8), "different")
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testOldJournalWithoutNewMetadataStillRestores() throws {
        let file = try fixture()
        let batch = try service.moveToTrash([file])
        let history = root.appendingPathComponent("history.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: history)) as! [[String: Any]]
        var entries = json[0]["entries"] as! [[String: Any]]
        entries[0].removeValue(forKey: "failure"); entries[0].removeValue(forKey: "itemIdentity")
        json[0]["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: history)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testInteractiveModePreservesSecurityBoundaries() throws {
        let app = try applicationFixture()
        service.runningApplications = { [.init(bundleID: "org.example.fixture", url: app.url, name: "测试应用")] }
        XCTAssertThrowsError(try service.validate(app, method: .systemInteractive))
        service.runningApplications = { [] }
        let wrongOwner = CleanFile(url: app.url, kind: .application, reason: "错误身份", ownerBundleID: "org.example.wrong")
        XCTAssertThrowsError(try service.validate(wrongOwner, method: .systemInteractive))
        let link = root.appendingPathComponent("Applications/Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app.url)
        XCTAssertThrowsError(try service.validate(CleanFile(url: link, kind: .application, reason: "测试"), method: .systemInteractive))
        XCTAssertThrowsError(try service.validate(CleanFile(url: root, kind: .cache, reason: "测试"), method: .systemInteractive))
    }

    func containerFixture() throws -> CleanFile {
        let url = root.appendingPathComponent("Library/Containers/org.example.retry")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("container data".utf8).write(to: url.appendingPathComponent("data"))
        return CleanFile(url: url, kind: .container, reason: "测试容器", ownerBundleID: "org.example.retry")
    }

    func testSuccessfulInteractiveRecycleNeverCallsRetry() throws {
        let file = try fixture()
        installMockRecycle()
        var retries = 0
        service.directRecycle = { _ in retries += 1; throw CleanError.refused("不应重试") }
        XCTAssertEqual(try service.moveToTrash([file], method: .systemInteractive).successCount, 1)
        XCTAssertEqual(retries, 0)
    }

    func testDeniedContainerRetriesWithinCurrentProcessAndRestores() throws {
        let file = try containerFixture()
        installMockRecycle()
        let move = service.systemRecycle
        var retries = 0
        service.systemRecycle = { _ in TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) }
        service.directRecycle = { url in
            retries += 1
            return try move(url).destinations.first?.value
        }
        let batch = try service.moveToTrash([file], method: .systemInteractive)
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(batch.successCount, 1)
        XCTAssertEqual(try service.restore(batchID: batch.id), 1)
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "container data")
    }

    func testDeniedApplicationRetriesBeforeProcessingOwnedData() throws {
        let app = try applicationFixture()
        let cache = try fixture("org.example.fixture")
        let owned = CleanFile(url: cache.url, kind: .cache, reason: "属于测试应用", ownerBundleID: app.ownerBundleID)
        installMockRecycle()
        let move = service.systemRecycle
        var retries: [URL] = []
        service.systemRecycle = { url in
            if url.path == app.url.path {
                return TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
            }
            return try move(url)
        }
        service.directRecycle = { url in
            retries.append(url)
            return try move(url).destinations.first?.value
        }
        let batch = try service.moveToTrash([owned, app], method: .systemInteractive)
        XCTAssertEqual(retries.map(\.path), [app.url.path])
        XCTAssertEqual(batch.successCount, 2)
        XCTAssertTrue(batch.entries.allSatisfy { $0.error == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path))
        XCTAssertEqual(try service.restore(batchID: batch.id), 2)
        XCTAssertEqual(ApplicationMetadata.information(at: app.url)?["CFBundleIdentifier"] as? String, "org.example.fixture")
        XCTAssertEqual(try String(contentsOf: owned.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testCancelledApplicationDoesNotRetryOrProcessOwnedData() throws {
        let app = try applicationFixture()
        let cache = try fixture("org.example.fixture")
        let owned = CleanFile(url: cache.url, kind: .cache, reason: "属于测试应用", ownerBundleID: app.ownerBundleID)
        var nativeCalls = 0, retries = 0
        service.systemRecycle = { _ in
            nativeCalls += 1
            return TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        service.directRecycle = { _ in retries += 1; return nil }
        let batch = try service.moveToTrash([owned, app], method: .systemInteractive)
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(batch.entries.first?.failure?.category, .cancelled)
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path))
    }

    func testApplicationRetryRejectsChangedApplicationIdentity() throws {
        let app = try applicationFixture()
        let preserved = root.appendingPathComponent("PreservedApplication")
        var retries = 0
        service.systemRecycle = { url in
            try FileManager.default.moveItem(at: url, to: preserved)
            _ = try self.applicationFixture()
            return TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }
        service.directRecycle = { _ in retries += 1; return nil }
        let batch = try service.moveToTrash([app], method: .systemInteractive)
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(batch.entries.first?.failure?.stage, .validation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertEqual(ApplicationMetadata.information(at: preserved)?["CFBundleIdentifier"] as? String, "org.example.fixture")
    }

    func testUserCancellationNeverCallsRetry() throws {
        let file = try containerFixture()
        var retries = 0
        service.systemRecycle = { _ in TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        service.directRecycle = { _ in retries += 1; return nil }
        let batch = try service.moveToTrash([file], method: .systemInteractive)
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(batch.entries.first?.failure?.category, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRetryRejectsSourceIdentityChange() throws {
        let file = try containerFixture()
        var retries = 0
        let preserved = root.appendingPathComponent("OriginalContainer")
        service.systemRecycle = { url in
            try FileManager.default.moveItem(at: url, to: preserved)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: url.appendingPathComponent("data"))
            return TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        }
        service.directRecycle = { _ in retries += 1; return nil }
        let batch = try service.moveToTrash([file], method: .systemInteractive)
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(batch.entries.first?.failure?.stage, .validation)
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: preserved.appendingPathComponent("data"), encoding: .utf8), "container data")
    }

    func testBothRecycleFailuresPreserveBothDiagnosticChains() throws {
        let file = try containerFixture()
        service.systemRecycle = { _ in TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) }
        service.directRecycle = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
        let batch = try service.moveToTrash([file], method: .systemInteractive)
        let failure = try XCTUnwrap(batch.entries.first?.failure)
        XCTAssertEqual(failure.category, .appData)
        XCTAssertEqual(failure.stage, .move)
        XCTAssertTrue(failure.systemCodes.contains { $0.contains("系统交互回收") && $0.contains(NSCocoaErrorDomain) })
        XCTAssertTrue(failure.systemCodes.contains { $0.contains("本进程回收") && $0.contains(NSPOSIXErrorDomain) })
        XCTAssertTrue(failure.message.contains("系统交互回收未完成") && failure.message.contains("本进程回收未完成"))
        XCTAssertEqual(failure.path, file.url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRetryRechecksAdditionalValidationBeforeMoving() throws {
        let file = try containerFixture()
        var retries = 0, checks = 0
        service.systemRecycle = { _ in TrashService.RecycleReply(destinations: [:], error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)) }
        service.directRecycle = { _ in retries += 1; return nil }
        let batch = try service.moveToTrash([file], method: .systemInteractive, additionalValidation: {
            checks += 1
            if checks > 2 { throw CleanError.refused("删除候选已被撤销") }
        })
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(batch.entries.first?.failure?.stage, .validation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testOptInFallbackCompletesSelectedDataAndRoundTrip() throws {
        let app = try applicationFixture()
        let cache = try fixture(), owned = CleanFile(url: cache.url, kind: .cache, reason: "测试", ownerBundleID: app.ownerBundleID)
        let snapshot = try service.review([owned, app])
        installMockRecycle()
        let move = service.systemRecycle
        var calls: [String] = []
        service.systemRecycle = { url in
            calls.append("系统" + url.lastPathComponent)
            if url.path == app.url.path { return .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) }
            return try move(url)
        }
        service.directRecycle = { url in
            calls.append("本进程" + url.lastPathComponent)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        service.finderRecycle = { url in
            calls.append("访达" + url.lastPathComponent)
            return try XCTUnwrap(move(url).destinations[url])
        }
        let batch = try service.moveToTrash([owned, app], method: .systemWithFinderFallback, reviewed: snapshot)
        XCTAssertEqual(calls, ["系统Example.app", "本进程Example.app", "访达Example.app", "系统org.example.demo"])
        XCTAssertEqual(batch.successCount, 2)
        XCTAssertEqual(batch.entries.first?.recycledByFinder, true)
        XCTAssertTrue(batch.entries.last?.recycledByFinder == nil)
        XCTAssertEqual(service.history().first?.entries.first?.recycledByFinder, true)
        XCTAssertEqual(try service.restore(batchID: batch.id), 2)
        XCTAssertEqual(try String(contentsOf: cache.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }

    func testOptInFallbackNeverPassesDataOrMislabelledApplication() throws {
        let cache = try fixture()
        service.systemRecycle = { _ in .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) }
        service.finderRecycle = { _ in preconditionFailure("访达不得接收数据") }
        let batch = try service.moveToTrash([cache], method: .systemWithFinderFallback)
        XCTAssertEqual(batch.entries.first?.failure?.category, .fileAccess)
        let fake = CleanFile(url: cache.url, kind: .application, reason: "错误类型", ownerBundleID: "org.example.fake")
        XCTAssertThrowsError(try service.moveToTrash([fake], method: .systemWithFinderFallback))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url.path))
    }

    func testOptInFallbackCancellationAndNonPermissionErrorsNeverRetry() throws {
        let first = try applicationFixture("First"), second = try applicationFixture("Second")
        service.systemRecycle = { _ in .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) }
        service.directRecycle = { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
        service.finderRecycle = { _ in preconditionFailure("取消或其他失败不能转入访达") }
        let cancelled = try service.moveToTrash([first, second], method: .systemWithFinderFallback)
        XCTAssertEqual(cancelled.entries.first?.failure?.category, .cancelled)
        XCTAssertEqual(cancelled.entries.last?.failure?.stage, .skipped)
        service.directRecycle = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        let failed = try service.moveToTrash([first], method: .systemWithFinderFallback)
        XCTAssertEqual(failed.entries.first?.failure?.category, .other)
    }

    func testFinderFallbackRetainsAllDiagnosticsAndPreservesOwnerData() throws {
        let app = try applicationFixture(), cache = try fixture()
        let owned = CleanFile(url: cache.url, kind: .cache, reason: "测试", ownerBundleID: app.ownerBundleID)
        service.systemRecycle = { _ in .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) }
        service.finderRecycle = { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1743) }
        let batch = try service.moveToTrash([app, owned], method: .systemWithFinderFallback)
        let failure = try XCTUnwrap(batch.entries.first?.failure)
        XCTAssertEqual(failure.category, .automation)
        XCTAssertEqual(failure.systemCodes.count, 3)
        XCTAssertTrue(failure.systemCodes.last?.contains("-1743") == true)
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url.path))
    }

    func testFinderAuthenticationCancelledStopsRemainingBatch() throws {
        let first = try applicationFixture("First"), second = try applicationFixture("Second")
        var attempts = 0
        service.systemRecycle = { _ in .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) }
        service.finderRecycle = { _ in
            attempts += 1
            throw NSError(domain: NSOSStatusErrorDomain, code: -60006)
        }
        let batch = try service.moveToTrash([first, second], method: .systemWithFinderFallback)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(batch.entries.first?.failure?.category, .cancelled)
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
    }

    func testNewSourceBetweenRetriesCannotGoToFinder() throws {
        let app = try applicationFixture()
        service.systemRecycle = { _ in .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) }
        service.directRecycle = { url in
            try FileManager.default.moveItem(at: url, to: self.root.appendingPathComponent("BeforeReplacement"))
            _ = try self.applicationFixture()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        service.finderRecycle = { _ in preconditionFailure("申请访达前文件身份已变") }
        let batch = try service.moveToTrash([app], method: .systemWithFinderFallback)
        XCTAssertEqual(batch.successCount, 0)
        XCTAssertEqual(batch.entries.first?.failure?.stage, .validation)
    }

    func testSelectionSnapshotRejectsReplacementBeforeAnyMove() throws {
        let first = try applicationFixture("First"), second = try applicationFixture("Second")
        let snapshot = try service.review([first, second])
        try FileManager.default.moveItem(at: second.url, to: root.appendingPathComponent("Preserved"))
        _ = try applicationFixture("Second")
        service.systemRecycle = { _ in preconditionFailure("应先检查所有已确认文件") }
        XCTAssertThrowsError(try service.moveToTrash([first, second], method: .systemWithFinderFallback, reviewed: snapshot))
        XCTAssertTrue(service.history().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
    }

    func testHistoricalFinderRecoveryRequiresExactFailedEntity() throws {
        let app = try applicationFixture()
        let record = AppRecord(url: app.url, name: "应用", bundleID: "org.example.fixture", version: "1")
        service.systemRecycle = { _ in .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) }
        _ = try service.moveToTrash([app], method: .systemInteractive)
        let entry = try XCTUnwrap(service.history().first?.entries.first)
        XCTAssertTrue(service.matchesFailedApplication(entry, application: record))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        var legacyIdentity = json["itemIdentity"] as! [String: Any]
        legacyIdentity.removeValue(forKey: "birthSeconds"); legacyIdentity.removeValue(forKey: "birthNanoseconds")
        json["itemIdentity"] = legacyIdentity
        let noBirth = try JSONDecoder().decode(TrashEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(service.matchesFailedApplication(noBirth, application: record))
        json.removeValue(forKey: "itemIdentity")
        let old = try JSONDecoder().decode(TrashEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(service.matchesFailedApplication(old, application: record))
        try FileManager.default.moveItem(at: app.url, to: root.appendingPathComponent("OldApplication"))
        _ = try applicationFixture()
        XCTAssertFalse(service.matchesFailedApplication(entry, application: record))
    }

    func testFallbackIndependentApplicationContinuesAfterRefusal() throws {
        let denied = try applicationFixture("Denied", owner: "org.example.denied")
        let allowed = try applicationFixture("Allowed", owner: "org.example.allowed")
        let firstCache = try fixture("org.example.denied"), secondCache = try fixture("org.example.allowed")
        let files = [denied, allowed, CleanFile(url: firstCache.url, kind: .cache, reason: "测试", ownerBundleID: denied.ownerBundleID),
                     CleanFile(url: secondCache.url, kind: .cache, reason: "测试", ownerBundleID: allowed.ownerBundleID)]
        installMockRecycle()
        let move = service.systemRecycle
        service.systemRecycle = { url in
            if url.path == denied.url.path { return .init(destinations: [:], error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) }
            return try move(url)
        }
        service.finderRecycle = { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -5000) }
        let batch = try service.moveToTrash(files, method: .systemWithFinderFallback)
        XCTAssertEqual(batch.successCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCache.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondCache.url.path))
        XCTAssertEqual(try service.restore(batchID: batch.id), 2)
    }

    func testPermissionReplyWithoutDestinationDoesNotReleaseApplicationData() throws {
        let app = try applicationFixture()
        let cache = try fixture("org.example.fixture")
        let owned = CleanFile(url: cache.url, kind: .cache, reason: "测试", ownerBundleID: app.ownerBundleID)
        installMockRecycle()
        let move = service.systemRecycle
        service.systemRecycle = { url in
            if url.path == app.url.path {
                return TrashService.RecycleReply(destinations: [url: self.root.appendingPathComponent("Trash/Missing.app")],
                    error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
            }
            return try move(url)
        }
        let batch = try service.moveToTrash([app, owned], method: .systemInteractive)
        XCTAssertEqual(batch.successCount, 0)
        XCTAssertEqual(batch.entries.last?.failure?.stage, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url.path))
        XCTAssertEqual(batch.entries.first?.failure?.category, .applicationManagement)
        XCTAssertTrue(batch.entries.first?.trashURL == nil)
        var finderCalls = 0
        service.finderRecycle = { url in
            XCTAssertEqual(url.path, app.url.path)
            finderCalls += 1
            return try XCTUnwrap(move(url).destinations[url])
        }
        let retried = try service.moveToTrash([app, owned], method: .systemWithFinderFallback, reviewed: service.review([app, owned]))
        XCTAssertEqual(finderCalls, 1)
        XCTAssertEqual(retried.successCount, 2)
        XCTAssertEqual(try service.restore(batchID: retried.id), 2)
    }

    func testInteractiveJournalFailureRollsBackCurrentFile() throws {
        let file = try fixture()
        installMockRecycle()
        var writes = 0
        service.beforeJournalWrite = { writes += 1; if writes == 2 { throw CleanError.refused("模拟写入失败") } }
        XCTAssertThrowsError(try service.moveToTrash([file], method: .systemInteractive))
        XCTAssertEqual(try String(contentsOf: file.url.appendingPathComponent("data"), encoding: .utf8), "test")
    }

}

#if TRASH_STANDALONE_TESTS
@main
struct TrashStandaloneTests {
    static func main() throws {
        let cases: [(String, (TrashServiceTests) -> () throws -> Void)] = [
            ("testSkipListStopsEveryRecycleMethodAndOtherCopies", TrashServiceTests.testSkipListStopsEveryRecycleMethodAndOtherCopies),
            ("testSkipListProtectsHelperDataAndSharedParent", TrashServiceTests.testSkipListProtectsHelperDataAndSharedParent),
            ("testNewProtectionAfterPreviewStopsExecution", TrashServiceTests.testNewProtectionAfterPreviewStopsExecution),
            ("testSkipListDoesNotBlockRecovery", TrashServiceTests.testSkipListDoesNotBlockRecovery),
            ("testFinderRecycleRoundTripUsesValidatedMapping", TrashServiceTests.testFinderRecycleRoundTripUsesValidatedMapping),
            ("testFinderModeRefusesDataBeforeAnyMove", TrashServiceTests.testFinderModeRefusesDataBeforeAnyMove),
            ("testFinderCancellationStopsLaterApplications", TrashServiceTests.testFinderCancellationStopsLaterApplications),
            ("testFinderAutomationDenialIsSpecific", TrashServiceTests.testFinderAutomationDenialIsSpecific),
            ("testFinderRejectsWrongTrashIdentity", TrashServiceTests.testFinderRejectsWrongTrashIdentity),
            ("testFinderArgumentsRemainLiteral", TrashServiceTests.testFinderArgumentsRemainLiteral),
            ("testRoundTripPreservesContent", TrashServiceTests.testRoundTripPreservesContent),
            ("单项恢复和重复恢复", TrashServiceTests.testRestoreOneEntryLeavesOtherInTrash),
            ("下载安装文件识别及回收恢复", TrashServiceTests.testInstallerDiscoveryAndRoundTrip),
            ("testAdditionalValidationStopsLaterMoves", TrashServiceTests.testAdditionalValidationStopsLaterMoves),
            ("testAppScriptDirectoryRoundtripAndOwnershipBoundaries", TrashServiceTests.testAppScriptDirectoryRoundtripAndOwnershipBoundaries),
            ("testBrowserChannelOnlyAllowsExactMappedDirectory", TrashServiceTests.testBrowserChannelOnlyAllowsExactMappedDirectory),
            ("testRejectsRootsAndOutOfBounds", TrashServiceTests.testRejectsRootsAndOutOfBounds),
            ("testSymbolicLinkCannotEscape", TrashServiceTests.testSymbolicLinkCannotEscape),
            ("testBatchPreflightPreventsPartialMutation", TrashServiceTests.testBatchPreflightPreventsPartialMutation),
            ("testRestoreDoesNotOverwrite", TrashServiceTests.testRestoreDoesNotOverwrite),
            ("testDeduplicatesNestedSelections", TrashServiceTests.testDeduplicatesNestedSelections),
            ("testProtectsAppleAndOwnData", TrashServiceTests.testProtectsAppleAndOwnData),
            ("testWrappedApplicationCanRoundTrip", TrashServiceTests.testWrappedApplicationCanRoundTrip),
            ("testWrappedApplicationCannotBorrowExternalIdentity", TrashServiceTests.testWrappedApplicationCannotBorrowExternalIdentity),
            ("testRejectsForgedRestoreSourceOutsideTrash", TrashServiceTests.testRejectsForgedRestoreSourceOutsideTrash),
            ("testRejectsForgedRestoreDestinationOutsideAllowedRoots", TrashServiceTests.testRejectsForgedRestoreDestinationOutsideAllowedRoots),
            ("testRestoreRejectsSymbolicLinkSourceAndChangedParent", TrashServiceTests.testRestoreRejectsSymbolicLinkSourceAndChangedParent),
            ("testRestoreDoesNotReplaceDanglingSymlink", TrashServiceTests.testRestoreDoesNotReplaceDanglingSymlink),
            ("testProtectsSystemNamesWithoutOwnerMetadata", TrashServiceTests.testProtectsSystemNamesWithoutOwnerMetadata),
            ("testInferredRunningOwnerBlocksUnlabelledCache", TrashServiceTests.testInferredRunningOwnerBlocksUnlabelledCache),
            ("testRunningNestedAppBlocksParentRemoval", TrashServiceTests.testRunningNestedAppBlocksParentRemoval),
            ("testNestedApplicationCannotBeRemovedSeparately", TrashServiceTests.testNestedApplicationCannotBeRemovedSeparately),
            ("testJournalFailureBeforeMoveLeavesFileUntouched", TrashServiceTests.testJournalFailureBeforeMoveLeavesFileUntouched),
            ("testJournalFailureAfterMoveRollsBackCurrentFile", TrashServiceTests.testJournalFailureAfterMoveRollsBackCurrentFile),
            ("testRestoreJournalFailureRollsBackToTrash", TrashServiceTests.testRestoreJournalFailureRollsBackToTrash),
            ("testMalformedJournalPreventsAnyMove", TrashServiceTests.testMalformedJournalPreventsAnyMove),
            ("testNormalizationUsesPathComponentsAndStandardizedURLs", TrashServiceTests.testNormalizationUsesPathComponentsAndStandardizedURLs),
            ("testRejectsNonFileURLs", TrashServiceTests.testRejectsNonFileURLs),
            ("testRunningNamedCacheAndRestoreOwnerAreProtected", TrashServiceTests.testRunningNamedCacheAndRestoreOwnerAreProtected),
            ("testLoadedOrUnknownLaunchAgentCannotBeRemoved", TrashServiceTests.testLoadedOrUnknownLaunchAgentCannotBeRemoved),
            ("testExactBrowserSubdirectoryCanRoundTripButVendorCannot", TrashServiceTests.testExactBrowserSubdirectoryCanRoundTripButVendorCannot),
            ("testByHostAllowsOnlyExactOwnerAndUUID", TrashServiceTests.testByHostAllowsOnlyExactOwnerAndUUID),
            ("testSymbolicJournalCannotRedirectWrites", TrashServiceTests.testSymbolicJournalCannotRedirectWrites),
            ("testSystemRecycleDenialPreservesApplicationDiagnostic", TrashServiceTests.testSystemRecycleDenialPreservesApplicationDiagnostic),
            ("testSystemRecycleDenialDistinguishesContainerAndFile", TrashServiceTests.testSystemRecycleDenialDistinguishesContainerAndFile),
            ("testSystemRecycleCancellationStopsFollowingItems", TrashServiceTests.testSystemRecycleCancellationStopsFollowingItems),
            ("testApplicationRefusalKeepsOwnedData", TrashServiceTests.testApplicationRefusalKeepsOwnedData),
            ("testApplicationRefusalWithoutOwnerMetadataKeepsOwnedData", TrashServiceTests.testApplicationRefusalWithoutOwnerMetadataKeepsOwnedData),
            ("testSuccessfulSystemMappingWithErrorRemainsRecoverable", TrashServiceTests.testSuccessfulSystemMappingWithErrorRemainsRecoverable),
            ("testSuccessfulMappingWithCancellationStopsFollowingItems", TrashServiceTests.testSuccessfulMappingWithCancellationStopsFollowingItems),
            ("testInvalidSystemMappingRetainsLocationWithoutRestoringWrongIdentity", TrashServiceTests.testInvalidSystemMappingRetainsLocationWithoutRestoringWrongIdentity),
            ("testSystemRecycleMappingMustBelongToRequestedItemAndTrash", TrashServiceTests.testSystemRecycleMappingMustBelongToRequestedItemAndTrash),
            ("testRestoreRejectsChangedTrashIdentity", TrashServiceTests.testRestoreRejectsChangedTrashIdentity),
            ("testOldJournalWithoutNewMetadataStillRestores", TrashServiceTests.testOldJournalWithoutNewMetadataStillRestores),
            ("testInteractiveModePreservesSecurityBoundaries", TrashServiceTests.testInteractiveModePreservesSecurityBoundaries),
            ("testSuccessfulInteractiveRecycleNeverCallsRetry", TrashServiceTests.testSuccessfulInteractiveRecycleNeverCallsRetry),
            ("testDeniedContainerRetriesWithinCurrentProcessAndRestores", TrashServiceTests.testDeniedContainerRetriesWithinCurrentProcessAndRestores),
            ("testDeniedApplicationRetriesBeforeProcessingOwnedData", TrashServiceTests.testDeniedApplicationRetriesBeforeProcessingOwnedData),
            ("testCancelledApplicationDoesNotRetryOrProcessOwnedData", TrashServiceTests.testCancelledApplicationDoesNotRetryOrProcessOwnedData),
            ("testApplicationRetryRejectsChangedApplicationIdentity", TrashServiceTests.testApplicationRetryRejectsChangedApplicationIdentity),
            ("testUserCancellationNeverCallsRetry", TrashServiceTests.testUserCancellationNeverCallsRetry),
            ("testRetryRejectsSourceIdentityChange", TrashServiceTests.testRetryRejectsSourceIdentityChange),
            ("testBothRecycleFailuresPreserveBothDiagnosticChains", TrashServiceTests.testBothRecycleFailuresPreserveBothDiagnosticChains),
            ("testRetryRechecksAdditionalValidationBeforeMoving", TrashServiceTests.testRetryRechecksAdditionalValidationBeforeMoving),
            ("testOptInFallbackCompletesSelectedDataAndRoundTrip", TrashServiceTests.testOptInFallbackCompletesSelectedDataAndRoundTrip),
            ("testOptInFallbackNeverPassesDataOrMislabelledApplication", TrashServiceTests.testOptInFallbackNeverPassesDataOrMislabelledApplication),
            ("testOptInFallbackCancellationAndNonPermissionErrorsNeverRetry", TrashServiceTests.testOptInFallbackCancellationAndNonPermissionErrorsNeverRetry),
            ("testFinderFallbackRetainsAllDiagnosticsAndPreservesOwnerData", TrashServiceTests.testFinderFallbackRetainsAllDiagnosticsAndPreservesOwnerData),
            ("testFinderAuthenticationCancelledStopsRemainingBatch", TrashServiceTests.testFinderAuthenticationCancelledStopsRemainingBatch),
            ("testNewSourceBetweenRetriesCannotGoToFinder", TrashServiceTests.testNewSourceBetweenRetriesCannotGoToFinder),
            ("testSelectionSnapshotRejectsReplacementBeforeAnyMove", TrashServiceTests.testSelectionSnapshotRejectsReplacementBeforeAnyMove),
            ("testHistoricalFinderRecoveryRequiresExactFailedEntity", TrashServiceTests.testHistoricalFinderRecoveryRequiresExactFailedEntity),
            ("testFallbackIndependentApplicationContinuesAfterRefusal", TrashServiceTests.testFallbackIndependentApplicationContinuesAfterRefusal),
            ("testPermissionReplyWithoutDestinationDoesNotReleaseApplicationData", TrashServiceTests.testPermissionReplyWithoutDestinationDoesNotReleaseApplicationData),
            ("testInteractiveJournalFailureRollsBackCurrentFile", TrashServiceTests.testInteractiveJournalFailureRollsBackCurrentFile)
        ]
        for (name, test) in cases {
            let instance = TrashServiceTests()
            try instance.setUpWithError()
            do { try test(instance)(); try instance.tearDownWithError() }
            catch { try? instance.tearDownWithError(); throw error }
            print("通过：" + name)
        }
        print("清理与恢复安全测试：\(cases.count) 项通过。")
    }
}
#endif
