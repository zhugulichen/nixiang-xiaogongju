import Foundation
#if !FEEDBACK_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private func feedbackEntry(moved: Bool = true, error: String? = nil, restored: Bool = false) -> TrashEntry {
    TrashEntry(originalURL: URL(fileURLWithPath: "/Applications/声音测试.app"),
               trashURL: moved ? URL(fileURLWithPath: "/Users/example/.Trash/声音测试.app") : nil,
               error: error, restored: restored)
}

private func feedbackBatch(_ entries: [TrashEntry], id: UUID = UUID()) -> TrashBatch {
    TrashBatch(id: id, date: Date(timeIntervalSince1970: 0), entries: entries)
}

private let feedbackChecks: [(String, () -> Bool)] = [
    ("普通回收成功允许系统音效", {
        let batch = feedbackBatch([feedbackEntry()])
        return CleanupSoundFeedback.shouldPlay(batch: batch, method: .systemInteractive, enabled: true)
            && CleanupSoundFeedback.shouldPlay(batch: batch, method: .direct, enabled: true)
    }),
    ("关闭音效时不提交请求", {
        var gate = CleanupSoundFeedbackGate()
        var calls = 0
        let result = gate.submit(batch: feedbackBatch([feedbackEntry()]), method: .systemInteractive, enabled: false) {
            calls += 1; return true
        }
        return !result && calls == 0
    }),
    ("空批次与未成功回收保持安静", {
        let cases = [feedbackBatch([]), feedbackBatch([feedbackEntry(moved: false)]),
                     feedbackBatch([feedbackEntry(moved: false, error: "已取消")])]
        return cases.allSatisfy {
            !CleanupSoundFeedback.shouldPlay(batch: $0, method: .systemInteractive, enabled: true)
        }
    }),
    ("已恢复或有错误的映射不算成功", {
        let batch = feedbackBatch([feedbackEntry(error: "文件身份未确认"), feedbackEntry(restored: true)])
        return !CleanupSoundFeedback.shouldPlay(batch: batch, method: .systemInteractive, enabled: true)
    }),
    ("部分成功只提交一次请求", {
        var gate = CleanupSoundFeedbackGate()
        var calls = 0
        let batch = feedbackBatch([feedbackEntry(), feedbackEntry(moved: false, error: "已取消")])
        let result = gate.submit(batch: batch, method: .systemInteractive, enabled: true) {
            calls += 1; return true
        }
        return result && calls == 1
    }),
    ("访达回收不额外补播", {
        var gate = CleanupSoundFeedbackGate()
        var calls = 0
        let result = gate.submit(batch: feedbackBatch([feedbackEntry()]), method: .finderInteractive, enabled: true) {
            calls += 1; return true
        }
        return !result && calls == 0
    }),
    ("本次允许访达重试时按实际成功的回收方式反馈", {
        guard let data = try? JSONEncoder().encode(feedbackEntry()),
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        record["recycledByFinder"] = true
        guard let amended = try? JSONSerialization.data(withJSONObject: record),
              let finderEntry = try? JSONDecoder().decode(TrashEntry.self, from: amended) else { return false }
        let method = TrashMoveMethod.systemWithFinderFallback
        return CleanupSoundFeedback.shouldPlay(batch: feedbackBatch([feedbackEntry()]), method: method, enabled: true)
            && !CleanupSoundFeedback.shouldPlay(batch: feedbackBatch([finderEntry, feedbackEntry()]), method: method, enabled: true)
    }),
    ("同一批次多次通知仅提交一次", {
        var gate = CleanupSoundFeedbackGate()
        var calls = 0
        let batch = feedbackBatch([feedbackEntry()])
        let first = gate.submit(batch: batch, method: .systemInteractive, enabled: true) { calls += 1; return true }
        let second = gate.submit(batch: batch, method: .systemInteractive, enabled: true) { calls += 1; return true }
        return first && !second && calls == 1
    }),
    ("不同批次分别提交且旧批次仍不重复", {
        var gate = CleanupSoundFeedbackGate()
        var calls = 0
        let first = feedbackBatch([feedbackEntry()]), second = feedbackBatch([feedbackEntry()])
        let a = gate.submit(batch: first, method: .systemInteractive, enabled: true) { calls += 1; return true }
        let b = gate.submit(batch: second, method: .systemInteractive, enabled: true) { calls += 1; return true }
        let duplicate = gate.submit(batch: first, method: .direct, enabled: true) { calls += 1; return true }
        return a && b && !duplicate && calls == 2
    }),
    ("音效准备失败不计为已提交", {
        var gate = CleanupSoundFeedbackGate()
        let batch = feedbackBatch([feedbackEntry()])
        let failed = gate.submit(batch: batch, method: .systemInteractive, enabled: true) { false }
        let retried = gate.submit(batch: batch, method: .systemInteractive, enabled: true) { true }
        let duplicate = gate.submit(batch: batch, method: .systemInteractive, enabled: true) { true }
        return !failed && retried && !duplicate
    }),
    ("未成功的早期结果不会吞掉后续成功通知", {
        var gate = CleanupSoundFeedbackGate()
        let id = UUID()
        let earlier = feedbackBatch([feedbackEntry(moved: false)], id: id)
        let later = feedbackBatch([feedbackEntry()], id: id)
        var calls = 0
        let first = gate.submit(batch: earlier, method: .systemInteractive, enabled: true) { calls += 1; return true }
        let second = gate.submit(batch: later, method: .systemInteractive, enabled: true) { calls += 1; return true }
        return !first && second && calls == 1
    })
]

#if FEEDBACK_STANDALONE_TESTS
@main private enum CleanupSoundFeedbackChecks {
    static func main() {
        for (name, check) in feedbackChecks {
            guard check() else {
                FileHandle.standardError.write(Data(("失败：" + name + "\n").utf8))
                exit(1)
            }
            print("通过：" + name)
        }
        print("清理音效反馈：\(feedbackChecks.count) 项检查通过")
    }
}
#else
final class CleanupSoundFeedbackTests: XCTestCase {
    func testFeedbackPolicyAndRequestDeduplication() {
        for (name, check) in feedbackChecks { XCTAssertTrue(check(), name) }
    }
}
#endif
