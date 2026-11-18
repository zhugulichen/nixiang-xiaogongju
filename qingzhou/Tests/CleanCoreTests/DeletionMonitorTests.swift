#if MONITOR_STANDALONE_TESTS
import Foundation
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(value(), "断言失败", file: file, line: line) }
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) { precondition(lhs == rhs, "值不相等：\(lhs) / \(rhs)", file: file, line: line) }
#else
import XCTest
@testable import CleanCore
#endif

final class DeletionMonitorTests: XCTestCase {
    var root: URL!
    var apps: URL!
    var trash: URL!
    var monitor: DeletionMonitor!
    let start = Date()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("QingzhouMonitor-" + UUID().uuidString)
        apps = root.appendingPathComponent("Applications")
        trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        monitor = DeletionMonitor(roots: [apps], home: root, trashRoots: [trash])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult func app(_ name: String = "Example", id: String = "org.example.monitor", parent: URL? = nil) throws -> URL {
        let app = (parent ?? apps).appendingPathComponent(name + ".app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleVersion": "1"], format: .xml, options: 0).write(to: info)
        return app
    }
    @discardableResult func move(_ url: URL) throws -> URL {
        let target = trash.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target); return target
    }
    func detect() async -> MonitorPollResult {
        _ = await monitor.poll(now: start.addingTimeInterval(10))
        return await monitor.poll(now: start.addingTimeInterval(13))
    }
    func testBaselineNeverRemindsOldTrash() async throws {
        try app("Old", parent: trash)
        let current = try app()
        let result = await monitor.poll(now: start)
        XCTAssertTrue(result.isBaselineReady); XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.trackedApplicationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }
    func testActualMoveWaitsForStabilityAndDeduplicates() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        let target = try move(url)
        let immediate = await monitor.poll(now: start.addingTimeInterval(1))
        XCTAssertTrue(immediate.candidates.isEmpty)
        let result = await monitor.poll(now: start.addingTimeInterval(4))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.app.url.path, url.path)
        XCTAssertEqual(result.candidates.first?.trashURL.path, target.path)
        let observed13 = await monitor.poll(now: start.addingTimeInterval(8)); XCTAssertEqual(observed13.candidates.count, 1)
    }
    func testRenameAndMovesElsewhereDoNotTrigger() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        let renamed = apps.appendingPathComponent("Renamed.app")
        try FileManager.default.moveItem(at: url, to: renamed)
        let observed1 = await detect(); XCTAssertTrue(observed1.candidates.isEmpty)
        let outside = root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: renamed, to: outside)
        let observed2 = await detect(); XCTAssertTrue(observed2.candidates.isEmpty)
    }
    func testReplacementAndInstalledDuplicatesSuppressReminders() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        try move(url); try app("NewVersion")
        let observed3 = await detect(); XCTAssertTrue(observed3.candidates.isEmpty)
    }
    func testReinstallCancelsPreviouslyQueuedReminder() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        try move(url)
        let observed14 = await detect(); XCTAssertEqual(observed14.candidates.count, 1)
        try app("Reinstalled")
        let observed4 = await monitor.poll(now: start.addingTimeInterval(20)); XCTAssertTrue(observed4.candidates.isEmpty)
    }
    func testAppleOwnAndIgnoredAppsAreExcluded() async throws {
        try app("Apple", id: "com.apple.example")
        try app("Qingzhou", id: "cn.local.qingzhou.helper")
        let ignored = try app()
        await monitor.configure(roots: [apps], ignoredBundleIDs: ["org.example.monitor"])
        let observed15 = await monitor.poll(now: start); XCTAssertEqual(observed15.trackedApplicationCount, 0)
        try move(ignored)
        let observed5 = await detect(); XCTAssertTrue(observed5.candidates.isEmpty)
    }
    func testOwnCleanupSuppressionDoesNotTriggerLater() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        let target = try move(url)
        await monitor.suppressRecycledApplications(at: [target])
        let observed6 = await detect(); XCTAssertTrue(observed6.candidates.isEmpty)
        let observed7 = await monitor.poll(now: start.addingTimeInterval(200)); XCTAssertTrue(observed7.candidates.isEmpty)
    }
    func testOwnCleanupDoesNotSilenceRestoredApplication() async throws {
        let url = try app()
        _ = await monitor.poll(now: start)
        let target = try move(url)
        await monitor.suppressRecycledApplications(at: [target])
        try FileManager.default.moveItem(at: target, to: url)
        let restored = await monitor.poll(now: start.addingTimeInterval(2))
        XCTAssertEqual(restored.trackedApplicationCount, 1)
        try move(url)
        let deletedAgain = await detect()
        XCTAssertEqual(deletedAgain.candidates.map(\.app.url.path), [url.path])
    }

    func testOwnCleanupDoesNotSilenceAnotherInstalledCopy() async throws {
        let first = try app("First")
        let second = try app("Second")
        _ = await monitor.poll(now: start)
        let target = try move(first)
        await monitor.suppressRecycledApplications(at: [target])
        try move(second)
        let result = await detect()
        XCTAssertEqual(result.candidates.map(\.app.url.path), [second.path])
    }

    func testMonitorTracksApplicationAtDeepestListedLevel() async throws {
        let directory = apps.appendingPathComponent("One/Two/Three/Four")
        let url = try app(parent: directory)
        let baseline = await monitor.poll(now: start)
        XCTAssertEqual(baseline.trackedApplicationCount, 1)
        try move(url)
        let result = await detect()
        XCTAssertEqual(result.candidates.map(\.app.url.path), [url.path])
    }

    func testDeepInstalledCopyPreventsReminder() async throws {
        let url = try app()
        let directory = apps.appendingPathComponent("One/Two/Three/Four")
        try app("AnotherCopy", parent: directory)
        _ = await monitor.poll(now: start)
        try move(url)
        let result = await detect()
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testDeepReinstallBlocksCleanupBeforeNextPoll() async throws {
        let url = try app()
        _ = await monitor.poll(now: start)
        try move(url)
        let result = await detect()
        XCTAssertEqual(result.candidates.count, 1)
        let directory = apps.appendingPathComponent("One/Two/Three/Four")
        try app("AnotherCopy", parent: directory)
        do {
            try DeletionMonitor.validateForCleanup(result.candidates[0], roots: [apps], trashRoots: [trash])
            preconditionFailure("没有阻止已在深层文件夹重新安装应用的清理")
        } catch {}
        let reinstalled = await monitor.poll(now: start.addingTimeInterval(15))
        XCTAssertTrue(reinstalled.candidates.isEmpty)
    }

    func testDismissRestoreAndDeleteAgain() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        let target = try move(url)
        let result = await detect()
        await monitor.dismiss(candidateID: result.candidates[0].id)
        let observed8 = await monitor.poll(now: start.addingTimeInterval(20)); XCTAssertTrue(observed8.candidates.isEmpty)
        try FileManager.default.moveItem(at: target, to: url)
        let observed9 = await monitor.poll(now: start.addingTimeInterval(21)); XCTAssertTrue(observed9.candidates.isEmpty)
        try move(url)
        _ = await monitor.poll(now: start.addingTimeInterval(22))
        let observed16 = await monitor.poll(now: start.addingTimeInterval(25)); XCTAssertEqual(observed16.candidates.count, 1)
    }
    func testMultipleMovesAreQueuedAndRestorationCancelsOne() async throws {
        let first = try app("First", id: "org.example.first")
        let second = try app("Second", id: "org.example.second")
        _ = await monitor.poll(now: start)
        let firstTarget = try move(first); try move(second)
        let observed17 = await detect(); XCTAssertEqual(observed17.candidates.count, 2)
        try FileManager.default.moveItem(at: firstTarget, to: first)
        let observed18 = await monitor.poll(now: start.addingTimeInterval(20)); XCTAssertEqual(observed18.candidates.count, 1)
    }
    func testResetDoesNotRemindAlreadyDeletedApplication() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        try move(url); let observed19 = await detect(); XCTAssertEqual(observed19.candidates.count, 1)
        await monitor.reset()
        let observed10 = await monitor.poll(now: start.addingTimeInterval(20)); XCTAssertTrue(observed10.candidates.isEmpty)
    }
    func testCopyWithSameIdentifierCannotImpersonateMovedFile() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        try FileManager.default.copyItem(at: url, to: trash.appendingPathComponent("Copy.app"))
        try FileManager.default.removeItem(at: url)
        let observed11 = await detect(); XCTAssertTrue(observed11.candidates.isEmpty)
    }
    func testTrashRemovalInvalidatesQueue() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        let target = try move(url); let observed20 = await detect(); XCTAssertEqual(observed20.candidates.count, 1)
        try FileManager.default.removeItem(at: target)
        let observed12 = await monitor.poll(now: start.addingTimeInterval(20)); XCTAssertTrue(observed12.candidates.isEmpty)
    }
    func testNewlyInstalledAppsBecomeTracked() async throws {
        _ = await monitor.poll(now: start)
        let url = try app(); let observed21 = await monitor.poll(now: start.addingTimeInterval(1)); XCTAssertEqual(observed21.trackedApplicationCount, 1)
        try move(url); let observed22 = await detect(); XCTAssertEqual(observed22.candidates.count, 1)
    }
    func testCleanupValidationRejectsRestoreAndReinstall() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        let target = try move(url)
        let result = await detect()
        let candidate = result.candidates[0]
        try DeletionMonitor.validateForCleanup(candidate, roots: [apps], trashRoots: [trash])
        try FileManager.default.moveItem(at: target, to: url)
        do { try DeletionMonitor.validateForCleanup(candidate, roots: [apps], trashRoots: [trash]); preconditionFailure("恢复后仍允许清理") } catch {}
        try move(url)
        try app("AnotherCopy")
        do { try DeletionMonitor.validateForCleanup(candidate, roots: [apps], trashRoots: [trash]); preconditionFailure("重装后仍允许清理") } catch {}
    }
    func testCleanupValidationRejectsChangedTrashIdentity() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        let target = try move(url)
        let result = await detect()
        let candidate = result.candidates[0]
        try FileManager.default.removeItem(at: target)
        try app(parent: trash)
        do { try DeletionMonitor.validateForCleanup(candidate, roots: [apps], trashRoots: [trash]); preconditionFailure("废纸篓副本替换后仍允许清理") } catch {}
    }
    func testCleanupValidationAllowsMissingOptionalAndRemovedAppRoots() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        try move(url)
        let candidate = (await detect()).candidates[0]
        try DeletionMonitor.validateForCleanup(candidate, roots: [apps, root.appendingPathComponent("MissingApplications"), url], trashRoots: [trash])
    }
    func testCleanupValidationRejectsUnreadableRoot() async throws {
        let url = try app(); _ = await monitor.poll(now: start)
        try move(url)
        let candidate = (await detect()).candidates[0]
        let restricted = root.appendingPathComponent("Restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        do { try DeletionMonitor.validateForCleanup(candidate, roots: [apps, restricted], trashRoots: [trash]); preconditionFailure("无读取权限时仍允许清理") } catch {}
    }
    func testWrappedIOSApplicationIdentityIsRecognized() async throws {
        let outer = apps.appendingPathComponent("Mobile.app")
        let inner = try app("Inner", parent: outer.appendingPathComponent("Wrapper"))
        try FileManager.default.createSymbolicLink(atPath: outer.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Inner.app")
        let observed23 = await monitor.poll(now: start); XCTAssertEqual(observed23.trackedApplicationCount, 1)
        try move(outer); let observed24 = await detect(); XCTAssertEqual(observed24.candidates.count, 1)
        _ = inner
    }
}

#if MONITOR_STANDALONE_TESTS
@main struct MonitorTestRunner {
    static func main() async throws {
        let tests: [(String, (DeletionMonitorTests) -> () async throws -> Void)] = [
            ("旧废纸篓不触发", DeletionMonitorTests.testBaselineNeverRemindsOldTrash),
            ("真实移动与稳定期去重", DeletionMonitorTests.testActualMoveWaitsForStabilityAndDeduplicates),
            ("改名移动不误报", DeletionMonitorTests.testRenameAndMovesElsewhereDoNotTrigger),
            ("升级与多副本不误报", DeletionMonitorTests.testReplacementAndInstalledDuplicatesSuppressReminders),
            ("重装取消待处理提醒", DeletionMonitorTests.testReinstallCancelsPreviouslyQueuedReminder),
            ("系统自身与忽略保护", DeletionMonitorTests.testAppleOwnAndIgnoredAppsAreExcluded),
            ("清舟自身卸载抑制", DeletionMonitorTests.testOwnCleanupSuppressionDoesNotTriggerLater),
            ("清舟回收后恢复再删除", DeletionMonitorTests.testOwnCleanupDoesNotSilenceRestoredApplication),
            ("清舟回收不屏蔽其他同标识副本", DeletionMonitorTests.testOwnCleanupDoesNotSilenceAnotherInstalledCopy),
            ("列表最深层应用可触发提醒", DeletionMonitorTests.testMonitorTracksApplicationAtDeepestListedLevel),
            ("保留的深层副本阻止提醒", DeletionMonitorTests.testDeepInstalledCopyPreventsReminder),
            ("深层重装先于轮询阻止清理", DeletionMonitorTests.testDeepReinstallBlocksCleanupBeforeNextPoll),
            ("忽略恢复再次删除", DeletionMonitorTests.testDismissRestoreAndDeleteAgain),
            ("多应用队列与恢复", DeletionMonitorTests.testMultipleMovesAreQueuedAndRestorationCancelsOne),
            ("重启基线不提醒旧垃圾", DeletionMonitorTests.testResetDoesNotRemindAlreadyDeletedApplication),
            ("同标识副本无法冒充", DeletionMonitorTests.testCopyWithSameIdentifierCannotImpersonateMovedFile),
            ("废纸篓删除取消队列", DeletionMonitorTests.testTrashRemovalInvalidatesQueue),
            ("新增应用进入监测", DeletionMonitorTests.testNewlyInstalledAppsBecomeTracked),
            ("手机包装应用监测", DeletionMonitorTests.testWrappedIOSApplicationIdentityIsRecognized),
            ("清理前恢复重装拒绝", DeletionMonitorTests.testCleanupValidationRejectsRestoreAndReinstall),
            ("清理前身份替换拒绝", DeletionMonitorTests.testCleanupValidationRejectsChangedTrashIdentity),
            ("不存在的可选目录与已删除应用根", DeletionMonitorTests.testCleanupValidationAllowsMissingOptionalAndRemovedAppRoots),
            ("无法读取目录时取消清理", DeletionMonitorTests.testCleanupValidationRejectsUnreadableRoot)
        ]
        for (name, run) in tests {
            let test = DeletionMonitorTests(); try test.setUpWithError()
            do { try await run(test)(); try test.tearDownWithError() }
            catch { try? test.tearDownWithError(); throw error }
            print("通过：" + name)
        }
        print("删除监测：\(tests.count) 项测试通过。")
    }
}
#endif
