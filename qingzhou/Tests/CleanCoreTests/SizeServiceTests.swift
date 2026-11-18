#if SIZE_STANDALONE_TESTS
import Foundation
class XCTestCase {}
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

final class SizeServiceTests: XCTestCase {
    private func withFixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QingzhouSizeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
    private func file(_ root: URL, _ relative: String, bytes: Int) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: path)
        return path
    }
    func testDeepHiddenAndDirectFiles() async throws {
        try await withFixture { root in
            let direct = try file(root, "visible", bytes: 33)
            _ = try file(root, ".hidden", bytes: 7)
            _ = try file(root, "App.app/Contents/Resources/deep/contents", bytes: 100)
            let results = await SizeService.measure([root, direct])
            XCTAssertEqual(results[root.standardizedFileURL.path], SizeMeasurement(bytes: 140, isComplete: true, inaccessibleCount: 0))
            XCTAssertEqual(results[direct.standardizedFileURL.path]?.bytes, 33)
        }
    }
    func testDoesNotFollowDirectoryOrFileLinks() async throws {
        try await withFixture { root in
            let target = try file(root, "outside/large", bytes: 500)
            let scanned = root.appendingPathComponent("scanned")
            _ = try file(scanned, "real", bytes: 10)
            try FileManager.default.createSymbolicLink(at: scanned.appendingPathComponent("linked-file"), withDestinationURL: target)
            try FileManager.default.createSymbolicLink(at: scanned.appendingPathComponent("linked-directory"), withDestinationURL: target.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(at: scanned.appendingPathComponent("loop"), withDestinationURL: scanned)
            let result = await SizeService.measure([scanned])
            XCTAssertEqual(result[scanned.standardizedFileURL.path], SizeMeasurement(bytes: 10, isComplete: true, inaccessibleCount: 0))
        }
    }
    func testRefusesRootAndAncestorSymlinks() async throws {
        try await withFixture { root in
            let target = try file(root, "target/data", bytes: 500)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
            let child = link.appendingPathComponent("data")
            let result = await SizeService.measure([link, child])
            for url in [link, child] {
                XCTAssertEqual(result[url.standardizedFileURL.path]?.bytes, 0)
                XCTAssertFalse(result[url.standardizedFileURL.path]?.isComplete ?? true)
                XCTAssertEqual(result[url.standardizedFileURL.path]?.inaccessibleCount, 1)
            }
        }
    }
    func testMissingPathReportsIncomplete() async throws {
        try await withFixture { root in
            let missing = root.appendingPathComponent("missing")
            let result = await SizeService.measure([missing])
            XCTAssertEqual(result[missing.standardizedFileURL.path], SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 1))
        }
    }
    func testCancellationReturnsPartialAndMarksRemainingRoots() async throws {
        try await withFixture { root in
            let directory = root.appendingPathComponent("many")
            for index in 0..<50 { _ = try file(directory, "item\(index)", bytes: 10) }
            let last = try file(root, "last", bytes: 70)
            var checks = 0
            let result = SizeService.measureSynchronously([directory, last]) {
                checks += 1; return checks > 20
            }
            XCTAssertFalse(result[directory.standardizedFileURL.path]?.isComplete ?? true)
            XCTAssertTrue((result[directory.standardizedFileURL.path]?.bytes ?? 500) < 500)
            XCTAssertEqual(result[last.standardizedFileURL.path], SizeMeasurement(bytes: 0, isComplete: false, inaccessibleCount: 0))
        }
    }
    func testAsyncCancellationPropagates() async throws {
        try await withFixture { root in
            _ = try file(root, "data", bytes: 100)
            let task = Task { () -> [String: SizeMeasurement] in
                withUnsafeCurrentTask { $0?.cancel() }
                return await SizeService.measure([root])
            }
            let result = await task.value
            XCTAssertFalse(result[root.standardizedFileURL.path]?.isComplete ?? true)
        }
    }
    func testEmptyAndDuplicateInputs() async throws {
        let empty = await SizeService.measure([])
        XCTAssertTrue(empty.isEmpty)
        try await withFixture { root in
            let results = await SizeService.measure([root, root])
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results[root.standardizedFileURL.path], SizeMeasurement(bytes: 0, isComplete: true, inaccessibleCount: 0))
        }
    }
    func testHardLinksCountLogicalNames() async throws {
        try await withFixture { root in
            let first = try file(root, "first", bytes: 100)
            try FileManager.default.linkItem(at: first, to: root.appendingPathComponent("second"))
            let result = await SizeService.measure([root])
            XCTAssertEqual(result[root.standardizedFileURL.path]?.bytes, 200)
        }
    }
}

#if SIZE_STANDALONE_TESTS
@main struct SizeTestRunner {
    static func main() async throws {
        let tests = SizeServiceTests()
        try await tests.testDeepHiddenAndDirectFiles()
        try await tests.testDoesNotFollowDirectoryOrFileLinks()
        try await tests.testRefusesRootAndAncestorSymlinks()
        try await tests.testMissingPathReportsIncomplete()
        try await tests.testCancellationReturnsPartialAndMarksRemainingRoots()
        try await tests.testAsyncCancellationPropagates()
        try await tests.testEmptyAndDuplicateInputs()
        try await tests.testHardLinksCountLogicalNames()
        print("完整容量统计：8 项测试通过")
    }
}
#endif
