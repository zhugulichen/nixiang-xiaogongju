import Foundation
#if !USAGE_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private struct UsageFailure: Error { let message: String }
private enum UsageChecks {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw UsageFailure(message: message) }
    }

    static func run() async throws -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("清舟使用记录-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); count += 1; print("通过：" + name)
        }
        func record(_ name: String, path: String? = nil, id: String = "org.example.usage", bytes: Int64 = 0) -> AppRecord {
            AppRecord(url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"), name: name, bundleID: id, version: "1", bytes: bytes)
        }
        func makeApp(_ name: String = UUID().uuidString, flat: Bool = false) throws -> AppRecord {
            let url = root.appendingPathComponent(name + ".app")
            let info = url.appendingPathComponent(flat ? "Info.plist" : "Contents/Info.plist")
            try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.usage"], format: .binary, options: 0).write(to: info)
            return AppRecord(url: url, name: name, bundleID: "org.example.usage", version: "1")
        }
        func sorted(_ apps: [AppRecord], dates: [String: Date] = [:], order: ApplicationSortOrder = .lastUsed,
                    filter: ApplicationUsageFilter = .all, query: String = "") -> [String] {
            ApplicationUsageService.applications(apps, lastUsed: dates, order: order, filter: filter, query: query, now: now, calendar: calendar).map(\.id)
        }
        let alpha = record("Alpha", bytes: 10)
        let beta = record("Beta", bytes: 20)
        let gamma = record("Gamma", bytes: 20)
        try test("名称按自然顺序排列") {
            let two = record("应用2"), ten = record("应用10")
            try require(sorted([ten, two], order: .name) == [two.id, ten.id], "自然名称排序错误")
        }
        try test("大小降序并按名称打破同值") {
            try require(sorted([alpha, gamma, beta], order: .size) == [beta.id, gamma.id, alpha.id], "大小排序或同值排序错误")
        }
        try test("最近使用优先，未知和未来日期在末尾") {
            let future = record("Future"), unknown = record("Unknown")
            let dates = [alpha.id: now.addingTimeInterval(-60), beta.id: now.addingTimeInterval(-120), future.id: now.addingTimeInterval(1)]
            try require(sorted([unknown, beta, future, alpha], dates: dates) == [alpha.id, beta.id, future.id, unknown.id], "最近日期或未知顺序错误")
        }
        try test("同名同日应用按完整路径稳定排序") {
            let first = record("Same", path: "/Applications/A/Same.app")
            let second = record("Same", path: "/Applications/B/Same.app")
            let dates = [first.id: now, second.id: now]
            try require(sorted([second, first], dates: dates) == sorted([first, second], dates: dates), "顺序受输入排列影响")
            try require(sorted([second, first], dates: dates) == [first.id, second.id], "完整路径未用作同值排序")
        }
        try test("闲置阈值包含边界，近期和未知不算闲置") {
            let cutoff = calendar.date(byAdding: .day, value: -30, to: now)!
            let unknown = record("Unknown"), future = record("Future")
            let dates = [alpha.id: cutoff, beta.id: cutoff.addingTimeInterval(1), gamma.id: cutoff.addingTimeInterval(-1), future.id: now.addingTimeInterval(1)]
            try require(sorted([unknown, beta, gamma, future, alpha], dates: dates, order: .name, filter: .idle(days: 30)) == [alpha.id, gamma.id], "闲置边界或未知分类错误")
        }
        try test("夏令时开始按日历减天而非固定秒数") {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone(identifier: "America/New_York")!
            let current = local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
            let cutoff = local.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
            try require(current.timeIntervalSince(cutoff) == 23 * 3_600, "夏令时测试基准无效")
            let rows = ApplicationUsageService.applications([alpha, beta], lastUsed: [alpha.id: cutoff, beta.id: cutoff.addingTimeInterval(1)], order: .name, filter: .idle(days: 1), query: "", now: current, calendar: local)
            try require(rows.map(\.id) == [alpha.id], "春季夏令时阈值错误")
        }
        try test("夏令时结束仍按日历减天") {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone(identifier: "America/New_York")!
            let current = local.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
            let cutoff = local.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
            try require(current.timeIntervalSince(cutoff) == 25 * 3_600, "夏令时测试基准无效")
            let rows = ApplicationUsageService.applications([alpha, beta], lastUsed: [alpha.id: cutoff, beta.id: cutoff.addingTimeInterval(1)], order: .name, filter: .idle(days: 1), query: "", now: current, calendar: local)
            try require(rows.map(\.id) == [alpha.id], "秋季夏令时阈值错误")
        }
        try test("非有限日期和未来日期只进入未知分组") {
            let nan = record("NaN"), infinite = record("Infinite"), future = record("Future"), missing = record("Missing")
            let dates = [alpha.id: now, nan.id: Date(timeIntervalSinceReferenceDate: .nan), infinite.id: Date(timeIntervalSinceReferenceDate: .infinity), future.id: now.addingTimeInterval(1)]
            let apps = [alpha, nan, infinite, future, missing]
            try require(Set(sorted(apps, dates: dates, filter: .unknown)) == Set([nan.id, infinite.id, future.id, missing.id]), "非有限日期未按未知处理")
            try require(sorted(apps, dates: dates, filter: .idle(days: 0)) == [alpha.id], "未知值被当成闲置")
        }
        try test("负闲置天数无结果，零天只包含已知日期") {
            let dates = [alpha.id: now, beta.id: now.addingTimeInterval(-60)]
            try require(sorted([alpha, beta], dates: dates, filter: .idle(days: -1)).isEmpty, "负阈值不应展示结果")
            try require(sorted([alpha, beta], dates: dates, filter: .idle(days: Int.min)).isEmpty, "极小阈值不能溢出")
            try require(Set(sorted([alpha, beta, gamma], dates: dates, filter: .idle(days: 0))) == Set([alpha.id, beta.id]), "零天阈值错误")
        }
        try test("极大闲置阈值不能因系统整数转换而绕回近期") {
            try require(sorted([alpha], dates: [alpha.id: now.addingTimeInterval(-60)], filter: .idle(days: Int.max)).isEmpty,
                        "极大天数绕回近期阈值")
        }
        try test("搜索包含名称、应用标识和完整路径") {
            let app = record("演示App", path: "/Applications/工具包/Demo.app", id: "org.example.Exact")
            for query in ["演示", "EXACT", "工具包", "  演示  "] {
                try require(sorted([app], query: query) == [app.id], "遗漏搜索范围：" + query)
            }
        }
        try test("无效当前时间保守地将所有记录归为未知") {
            let rows = ApplicationUsageService.applications([alpha], lastUsed: [alpha.id: now], order: .lastUsed, filter: .idle(days: 1), query: "", now: Date(timeIntervalSinceReferenceDate: .nan), calendar: calendar)
            try require(rows.isEmpty, "无效当前时间仍计算闲置阈值")
        }

        let valid = try makeApp()
        let known = try await ApplicationUsageService.readLastUsed(for: [valid], now: now, dateReader: { _ in now.addingTimeInterval(-60) })
        try test("读取器只保留索引返回的有效日期") {
            try require(known[valid.id] == now.addingTimeInterval(-60), "索引日期未返回")
        }
        let flat = try makeApp(flat: true)
        let flatDates = try await ApplicationUsageService.readLastUsed(for: [flat], now: now, dateReader: { _ in now })
        try test("支持平面应用信息文件") { try require(flatDates[flat.id] == now, "遗漏平面信息文件") }
        let wrappedURL = root.appendingPathComponent(UUID().uuidString + ".app")
        let phone = wrappedURL.appendingPathComponent("Wrapper/Phone.app")
        try fm.createDirectory(at: phone, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.usage"], format: .binary, options: 0).write(to: phone.appendingPathComponent("Info.plist"))
        try fm.createSymbolicLink(atPath: wrappedURL.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Phone.app")
        let wrapped = AppRecord(url: wrappedURL, name: "手机包装应用", bundleID: "org.example.usage", version: "1")
        let wrappedDates = try await ApplicationUsageService.readLastUsed(for: [wrapped], now: now, dateReader: { _ in now })
        try test("手机包装应用只接受内部的指定别名") { try require(wrappedDates[wrapped.id] == now, "内部包装应用未被识别") }
        try fm.removeItem(at: wrappedURL.appendingPathComponent("WrappedBundle"))
        try fm.createSymbolicLink(at: wrappedURL.appendingPathComponent("WrappedBundle"), withDestinationURL: flat.url)
        var wrapperQueried = false
        let escapedDates = try await ApplicationUsageService.readLastUsed(for: [wrapped], now: now, dateReader: { _ in wrapperQueried = true; return now })
        try test("包装别名不能引入应用外的信息文件") { try require(escapedDates.isEmpty && !wrapperQueried, "包装别名越界") }
        let missing = try await ApplicationUsageService.readLastUsed(for: [valid], now: now, dateReader: { _ in nil })
        try test("没有索引日期时不借用文件日期") { try require(missing.isEmpty, "用文件访问或修改日期冒充使用记录") }
        for invalid in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity), now.addingTimeInterval(1)] {
            let rows = try await ApplicationUsageService.readLastUsed(for: [valid], now: now, dateReader: { _ in invalid })
            try test("读取器忽略异常或未来索引日期") { try require(rows.isEmpty, "无效索引日期进入结果") }
        }
        let symlink = root.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: valid.url)
        var queried = false
        let linked = AppRecord(url: symlink, name: "Link", bundleID: valid.bundleID, version: "1")
        let linkedDates = try await ApplicationUsageService.readLastUsed(for: [linked], now: now, dateReader: { _ in queried = true; return now })
        try test("符号链接应用不读取索引") { try require(linkedDates.isEmpty && !queried, "符号链接应用被接纳") }
        let parentLink = root.appendingPathComponent("ParentLink")
        try fm.createSymbolicLink(at: parentLink, withDestinationURL: root)
        let alias = AppRecord(url: parentLink.appendingPathComponent(valid.url.lastPathComponent), name: "Alias", bundleID: valid.bundleID, version: "1")
        queried = false
        let aliasDates = try await ApplicationUsageService.readLastUsed(for: [alias], now: now, dateReader: { _ in queried = true; return now })
        try test("祖先符号链接不能成为索引入口") { try require(aliasDates.isEmpty && !queried, "祖先链接绕过路径限制") }
        let changed = try makeApp()
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.replaced"], format: .binary, options: 0).write(to: changed.url.appendingPathComponent("Contents/Info.plist"))
        queried = false
        let changedDates = try await ApplicationUsageService.readLastUsed(for: [changed], now: now, dateReader: { _ in queried = true; return now })
        try test("扫描后应用身份变化不沿用旧使用记录") { try require(changedDates.isEmpty && !queried, "身份变化未被拦截") }
        let removedID = try makeApp()
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Missing"], format: .binary, options: 0).write(to: removedID.url.appendingPathComponent("Contents/Info.plist"))
        queried = false
        let removedDates = try await ApplicationUsageService.readLastUsed(for: [removedID], now: now, dateReader: { _ in queried = true; return now })
        try test("应用标识缺失保持未知") { try require(removedDates.isEmpty && !queried, "缺失标识仍触发查询") }
        let forgedInfo = try makeApp()
        let originalInfo = forgedInfo.url.appendingPathComponent("Contents/Info.plist")
        try fm.removeItem(at: originalInfo)
        try fm.createSymbolicLink(at: originalInfo, withDestinationURL: valid.url.appendingPathComponent("Contents/Info.plist"))
        queried = false
        let forgedDates = try await ApplicationUsageService.readLastUsed(for: [forgedInfo], now: now, dateReader: { _ in queried = true; return now })
        try test("信息文件符号链接不能借用外部身份") { try require(forgedDates.isEmpty && !queried, "外部信息链接被读取") }
        let replaced = try makeApp()
        let sameIDReplacement = try makeApp()
        let replacedDates = try await ApplicationUsageService.readLastUsed(for: [replaced], now: now, dateReader: { _ in
            try? fm.moveItem(at: replaced.url, to: root.appendingPathComponent("Old.app"))
            try? fm.moveItem(at: sameIDReplacement.url, to: replaced.url)
            return now
        })
        try test("读取期间替换同标识应用目录也丢弃结果") { try require(replacedDates.isEmpty, "目录替换后沿用了旧查询") }
        let edited = try makeApp()
        let editedDates = try await ApplicationUsageService.readLastUsed(for: [edited], now: now, dateReader: { _ in
            try? PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.changed"], format: .binary, options: 0).write(to: edited.url.appendingPathComponent("Contents/Info.plist"))
            return now
        })
        try test("读取期间修改应用标识丢弃结果") { try require(editedDates.isEmpty, "查询期间身份改变未被发现") }
        let huge = try makeApp()
        try Data(repeating: 0, count: 2_000_001).write(to: huge.url.appendingPathComponent("Contents/Info.plist"))
        queried = false
        let hugeDates = try await ApplicationUsageService.readLastUsed(for: [huge], now: now, dateReader: { _ in queried = true; return now })
        try test("超大信息文件保守跳过") { try require(hugeDates.isEmpty && !queried, "超大信息文件触发读取") }
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await ApplicationUsageService.readLastUsed(for: [valid]); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        try test("预先取消会传播取消结果") { try require(cancelled, "取消被吞掉") }
        var calls = 0
        let interrupted = await Task {
            do {
                _ = try await ApplicationUsageService.readLastUsed(for: [valid, flat], now: now, dateReader: { _ in
                    calls += 1; withUnsafeCurrentTask { $0?.cancel() }; return now
                })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        try test("读取中取消不发布部分结果且停止后续查询") { try require(interrupted && calls == 1, "读取中取消未立即停止") }
        return count
    }
}

#if USAGE_STANDALONE_TESTS
@main struct ApplicationUsageRunner {
    static func main() async throws {
        let count = try await UsageChecks.run()
        print("应用使用记录：\(count) 项检查通过")
    }
}
#else
final class ApplicationUsageTests: XCTestCase {
    func testUsageChecks() async throws { _ = try await UsageChecks.run() }
}
#endif
