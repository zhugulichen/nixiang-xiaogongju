import Foundation
#if !FEATURES13_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private struct FeatureFailure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw FeatureFailure(message: message) }
}

private enum Feature13Checks {
    static let header = ",bytes_in,bytes_out,"
    static func frame(_ lines: [String]) -> NetworkTrafficSample {
        var parser = NetworkTrafficParser()
        _ = parser.consume(header, at: Date(timeIntervalSince1970: 0))
        _ = parser.consume("old.1,999999,999999,")
        _ = parser.consume(header, at: Date(timeIntervalSince1970: 2))
        for line in lines { _ = parser.consume(line) }
        return parser.consume(header, at: Date(timeIntervalSince1970: 4))!
    }
    static let network: [(String, () throws -> Void)] = [
        ("首帧历史流量不记入本轮", {
            var parser = NetworkTrafficParser()
            try expect(parser.consume(header) == nil, "首个标题不能产生采样")
            _ = parser.consume("app.1,900000,500000,")
            try expect(parser.consume(header) == nil, "必须丢弃累计历史帧")
        }),
        ("有限采样最后一帧仍能读取", {
            var parser = NetworkTrafficParser()
            _ = parser.consume(header, at: Date(timeIntervalSince1970: 10))
            _ = parser.consume("app.3,9000,8000,")
            _ = parser.consume(header, at: Date(timeIntervalSince1970: 11))
            _ = parser.consume("app.3,80,20,")
            let sample = parser.finish()
            try expect(sample?.duration == 1 && sample?.processes.first?.received == 80, "结束时必须返回增量帧")
        }),
        ("仅有基线的有限采样不能当作新流量", {
            var parser = NetworkTrafficParser()
            _ = parser.consume(header)
            _ = parser.consume("app.3,9000,8000,")
            try expect(parser.finish() == nil, "历史累计必须排除")
        }),
        ("采样时长和双向流量", {
            let sample = frame(["app.42,100,200,"])
            try expect(sample.duration == 2 && sample.processes[0].received == 100 && sample.processes[0].sent == 200, "流量或时长错误")
        }),
        ("带点的进程名和带逗号的引号字段", {
            let sample = frame(["\"my.app, helper.42\",100,200,"])
            try expect(sample.processes[0].name == "my.app, helper" && sample.processes[0].pid == 42, "应从最后一个点提取进程号")
        }),
        ("列顺序变化", {
            var p = NetworkTrafficParser()
            _ = p.consume(",bytes_out,bytes_in,"); _ = p.consume(",bytes_out,bytes_in,")
            _ = p.consume("app.9,2,5,")
            try expect(p.consume(",bytes_out,bytes_in,")?.processes[0].received == 5, "必须按标题读取列")
        }),
        ("负数和超范围计数不伪造流量", {
            let s = frame(["app.9,-1,4,", "other.10,18446744073709551616,3,"])
            try expect(s.processes.isEmpty && s.skippedRows == 2, "非法计数必须跳过并报告")
        }),
        ("格式损坏和重复进程不重复计数", {
            let s = frame(["app.9,1,2,", "app.9,1,2,", "broken", "\"unclosed.2,2,3,"])
            try expect(s.processes.count == 1 && s.skippedRows == 3, "应标记部分统计")
        }),
        ("同应用辅助进程合并且计算速率", {
            var t = NetworkTrafficTotals()
            t.consume(frame(["one.1,100,20,", "two.2,300,60,"]), appURL: { _ in URL(fileURLWithPath: "/Applications/One.app") })
            let row = t.rows.values.first!
            try expect(t.rows.count == 1 && row.received == 400 && row.receiveRate == 200 && row.activeProcesses == 2, "应用合并错误")
        }),
        ("同名未知进程不会被误合并", {
            var t = NetworkTrafficTotals()
            t.consume(frame(["same.1,1,2,", "same.2,3,4,"]), appURL: { _ in nil })
            try expect(t.rows.count == 2, "不能仅按名字判断应用归属")
        }),
        ("不活跃应用本轮速率归零但累计保留", {
            var t = NetworkTrafficTotals()
            t.consume(frame(["one.1,100,20,"]), appURL: { _ in nil })
            t.consume(frame([]), appURL: { _ in nil })
            let row = t.rows.values.first!
            try expect(row.receiveRate == 0 && row.received == 100 && t.observedDuration == 4, "不可保留过期速率")
        }),
        ("累计数值溢出保护", {
            var t = NetworkTrafficTotals()
            let s = frame(["one.1,18446744073709551615,1,"])
            t.consume(s, appURL: { _ in nil }); t.consume(s, appURL: { _ in nil })
            try expect(t.rows.values.first?.received == UInt64.max, "累计不能溢出崩溃")
        })
    ]
    static func batch() throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QingzhouBatchTests-" + UUID().uuidString)
        let home = root.appendingPathComponent("Home"), apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, _ bid: String, title: String? = nil) throws -> AppRecord {
            let url = apps.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bid, "CFBundleName": title ?? name], format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
            return AppRecord(url: url, name: title ?? name, bundleID: bid, version: "1")
        }
        func file(_ path: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test".utf8).write(to: url)
        }
        let a = try app("Alpha", "org.test.alpha"), b = try app("Beta", "org.test.beta")
        try file("Library/Caches/org.test.alpha/data"); try file("Library/Caches/org.test.beta/data")
        try file("Library/Preferences/org.test.alpha.plist")
        let scanner = AppScanner(home: home, applicationRoots: [apps])
        let plan = try BatchCleanupPlanner.plan(apps: [a, b], installed: [a, b], scanner: scanner)
        try expect(plan.files.filter { $0.kind == .application && $0.defaultSelected }.count == 2, "两个应用本体应进入预览")
        try expect(plan.files.filter { $0.kind == .cache && $0.defaultSelected }.count == 2, "独占缓存可默认选择")
        try expect(plan.files.first { $0.kind == .preference }?.defaultSelected == false, "个人设置不得默认勾选")
        let duplicate = try BatchCleanupPlanner.plan(apps: [a, a], installed: [a], scanner: scanner)
        try expect(duplicate.apps.count == 1 && Set(duplicate.files.map(\.id)).count == duplicate.files.count, "重复应用和路径必须合并")
        let copy = try app("AlphaCopy", a.bundleID)
        let remaining = try BatchCleanupPlanner.plan(apps: [a], installed: [a, copy], scanner: scanner)
        try expect(remaining.files.filter { $0.kind != .application }.allSatisfy { $0.risk == .protected && !$0.defaultSelected }, "未选副本的数据须保护")
        let x = try app("SharedOne", "org.test.one", title: "Shared"), y = try app("SharedTwo", "org.test.two", title: "Shared")
        try file("Library/Caches/Shared/data")
        let shared = try BatchCleanupPlanner.plan(apps: [x, y], installed: [x, y], scanner: scanner)
        try expect(shared.files.first { $0.url.lastPathComponent == "Shared" }?.risk == .protected, "跨应用共享路径须保护")
        func helper(in app: AppRecord, identifier: String) throws {
            let contents = app.url.appendingPathComponent("Contents/Helpers/Worker.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        func isProtected(_ plan: BatchCleanupPlan, path: String) -> Bool {
            let file = plan.files.first { $0.url.standardizedFileURL.path == home.appendingPathComponent(path).standardizedFileURL.path }
            return file?.risk == .protected && file?.defaultSelected == false
        }
        try helper(in: a, identifier: "org.test.sharedworker"); try helper(in: b, identifier: "org.test.sharedworker")
        try file("Library/Caches/org.test.sharedworker/data")
        let helperPlan = try BatchCleanupPlanner.plan(apps: [a], installed: [a, b], scanner: scanner)
        try expect(isProtected(helperPlan, path: "Library/Caches/org.test.sharedworker"), "未选应用仍使用同标识辅助程序，必须保护其共享缓存")
        let oneNamed = try BatchCleanupPlanner.plan(apps: [x], installed: [x, y], scanner: scanner)
        try expect(isProtected(oneNamed, path: "Library/Caches/Shared"), "未选同名应用的关联目录必须保护")
        let vendor = try app("Vendor", "org.test.vendor", title: "Google"), chrome = try app("Browser", "com.google.Chrome")
        try file("Library/Caches/Google/Chrome/data")
        let parent = try BatchCleanupPlanner.plan(apps: [vendor], installed: [vendor, chrome], scanner: scanner)
        try expect(isProtected(parent, path: "Library/Caches/Google"), "待清理父目录包含未选应用数据时必须保护")
        let child = try BatchCleanupPlanner.plan(apps: [chrome], installed: [vendor, chrome], scanner: scanner)
        try expect(isProtected(child, path: "Library/Caches/Google/Chrome"), "待清理子目录位于未选应用关联目录内时必须保护")
        let lightweight = scanner.relatedFiles(for: chrome, measureSizes: false)
        try expect(lightweight.allSatisfy { $0.bytes == 0 } && Set(lightweight.map(\.id)) == Set(scanner.relatedFiles(for: chrome).map(\.id)), "轻量归属检查须保留所有路径并跳过容量遍历")
        let protected = AppRecord(url: a.url, name: a.name, bundleID: a.bundleID, version: "1", isProtected: true)
        for selected in [[], [protected], [AppRecord(url: root.appendingPathComponent("Outside.app"), name: "Outside", bundleID: "org.test.out", version: "1")]] {
            do { _ = try BatchCleanupPlanner.plan(apps: selected, installed: [], scanner: scanner); throw FeatureFailure(message: "错误地接受受保护、范围外或空选择") }
            catch is CleanError {}
        }
        print("批量卸载：14 项检查通过")
        return 14
    }
}

#if FEATURES13_STANDALONE_TESTS
@main struct Feature13Runner {
    static func main() throws {
        for (name, check) in Feature13Checks.network { try check(); print("通过：" + name) }
        let batch = try Feature13Checks.batch()
        print("新增功能：\(Feature13Checks.network.count + batch) 项检查通过")
    }
}
#else
final class Feature13Tests: XCTestCase {
    func testNetworkParsingAndAggregation() throws { for (_, check) in Feature13Checks.network { try check() } }
    func testBatchSafety() throws { _ = try Feature13Checks.batch() }
}
#endif
