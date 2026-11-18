import Foundation
#if !UPDATE_CENTER_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private actor UpdateProbe {
    var calls: [String] = []
    var waiting: CheckedContinuation<Void, Never>?
    var blocked = false
    func check(_ app: AppRecord, source: String) async -> UpdateInfo {
        calls.append(source + app.id)
        if blocked { await withCheckedContinuation { waiting = $0 } }
        return UpdateInfo(appID: app.id, status: .available, latestVersion: "2", url: nil, message: source)
    }
    func block() { blocked = true }
    func release() { blocked = false; waiting?.resume(); waiting = nil }
}

@MainActor private enum UpdateCenterChecks {
    static func run() async throws {
        var count = 0
        func expect(_ ok: Bool, _ name: String) {
            precondition(ok, name); count += 1; print("通过：" + name)
        }
        func wait(until condition: () async -> Bool) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await condition()) {
                precondition(ContinuousClock.now < end, "异步更新测试超时")
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let token = UUID().uuidString
        let suite = "org.example.qingzhou.update-test." + token
        let prefs = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("qingzhou-update-" + token)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let bid = "org.example.storetest"
        let feedURL = URL(string: "https://example.invalid/update.xml")!
        func record(_ path: String, id: String, store: Bool = false, feed: Bool = false, protected: Bool = false, version: String = "1.1") -> AppRecord {
            AppRecord(url: root.appendingPathComponent(path + ".app"), name: path, bundleID: id, version: version,
                      isProtected: protected, feedURL: feed ? feedURL : nil, hasStoreReceipt: store)
        }
        let shop = record("商品", id: bid, store: true, feed: true)
        let developer = record("开发者", id: "org.example.feed", feed: true)
        let copy = record("副本", id: developer.bundleID, feed: true)
        let manual = record("手动", id: "org.example.manual")
        let system = record("受保护", id: "org.example.system", feed: true, protected: true)
        let inventory = [shop, developer, copy, manual, system]
        func metadata(_ app: AppRecord, version: String? = nil, id: String? = nil, feed: URL? = nil) throws {
            let contents = app.url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist = ["CFBundleIdentifier": id ?? app.bundleID, "CFBundleShortVersionString": version ?? app.version]
            plist["SUFeedURL"] = (feed ?? app.feedURL)?.absoluteString
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        }
        for app in inventory { try metadata(app) }
        let receipt = shop.url.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        expect(!ApplicationMetadata.hasNativeStoreReceipt(at: shop.url), "缺少商店收据时不推测来源")
        try Data([0x01]).write(to: receipt)
        expect(ApplicationMetadata.hasNativeStoreReceipt(at: shop.url), "识别原生应用包内的普通收据文件")
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shop.url)
        expect(!ApplicationMetadata.hasNativeStoreReceipt(at: alias), "来源识别拒绝祖先符号链接")
        expect(ApplicationUpdateSource.source(for: shop) == .store, "带收据和开发者源的应用走商店渠道")
        expect(!StoreUpdateService.supports(region: "XX") && StoreUpdateService.supports(region: " cn "), "商店地区校验与规范化")
        let url = try StoreUpdateService.requestURL(for: shop, region: " CN ")
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        expect(url.host == "itunes.apple.com" && url.scheme == "https" && Set(params.map(\.name)) == ["entity", "bundleId", "country"] && params.first(where: { $0.name == "country" })?.value == "cn", "商店查询仅发送标识、产品类别和地区")
        expect((try? StoreUpdateService.requestURL(for: developer, region: "cn")) == nil, "没有收据的应用不会查询商店")
        func product(kind: String = "mac-software", id: String = "org.example.storetest", version: String = "1.2", os: String = "14") -> [String: Any] {
            ["kind": kind, "bundleId": id, "version": version, "minimumOsVersion": os, "trackId": 72, "trackViewUrl": "https://example.invalid"]
        }
        func result(_ products: [[String: Any]], app: AppRecord = shop) throws -> UpdateInfo {
            let data = try JSONSerialization.data(withJSONObject: ["results": products])
            return try StoreUpdateService.result(data: data, for: app, region: "cn", systemVersion: "15.1")
        }
        let newer = try result([product(kind: "software"), product()])
        expect(newer.status == .available && newer.url?.absoluteString == "https://apps.apple.com/cn/app/id72", "比对同标识电脑版本并生成苹果商品链接")
        expect(try result([product(version: "1.1.0")]).status == .upToDate, "末尾零不视为更高版本")
        expect(try result([product(os: "16.0")]).status == .failed, "新版本要求更高系统时不会列为可更新")
        expect((try? result([product(kind: "software"), product(id: "com.other.product")])) == nil, "手机应用和不同标识不能代替电脑应用")
        expect((try? result([product(), product()])) == nil && (try? result([])) == nil, "重名多条或无记录显示未知")
        expect((try? result([product(version: "1.4-beta")])) == nil, "非数字商店版本不作版本结论")
        let probe = UpdateProbe()
        let center = ApplicationUpdateCenter(defaults: prefs, feedCheck: { await probe.check($0, source: "开发者") }, storeCheck: { await probe.check($0, source: $1) })
        expect(center.developerTargets(in: inventory).map(\.id) == [developer.id, copy.id], "批量开发者检查排除商店、手动及系统应用")
        center.checkFeeds(inventory)
        try await wait { !center.checking }
        expect(center.completed == 2 && center.results.count == 2, "逐副本保存开发者检查结果")
        center.checkStore(shop, region: "cn")
        try await wait { !center.checking }
        expect(center.results[shop.id]?.message == "cn" && center.results[developer.id] != nil, "单独查询商店保留其他渠道结果")
        center.ignore(developer, in: inventory)
        expect(center.isIgnored(copy) && center.results[copy.id] == nil && center.results[developer.id] == nil && center.results[shop.id] != nil, "忽略标识会清除其所有副本的旧结果")
        let reopened = ApplicationUpdateCenter(defaults: prefs)
        expect(reopened.isIgnored(copy) && reopened.developerTargets(in: inventory).isEmpty, "重开后继续跳过同标识副本")
        center.resume(bundleID: developer.bundleID)
        await probe.block(); center.checkFeeds([developer])
        try await wait { await probe.waiting != nil }
        center.inventoryWillChange()
        await probe.release(); center.checkStore(shop, region: "us")
        try await wait { !center.checking }
        expect(center.results.count == 1 && center.results[shop.id]?.message == "us" && center.completed == 1, "重新扫描后的迟到回复不串入下一轮")
        center.ignore(shop, in: inventory); center.checkStore(shop, region: "cn")
        expect(!center.checking && center.results[shop.id] == nil, "忽略商店应用时不提交单项查询")
        let before = await probe.calls.count
        try metadata(developer, version: "2.0"); center.checkFeeds([developer]); try await wait { !center.checking }
        expect(center.results[developer.id]?.status == .failed && center.results[developer.id]?.url == nil, "原地升级后不再按旧版本显示可更新")
        try metadata(developer, feed: URL(string: "https://example.invalid/changed.xml")); center.checkFeeds([developer]); try await wait { !center.checking }
        expect(await probe.calls.count == before, "版本或更新源变化时不会联系旧来源")
        center.resume(bundleID: shop.bundleID); try metadata(shop, id: "org.example.replaced"); center.checkStore(shop, region: "cn"); try await wait { !center.checking }
        let after = await probe.calls.count
        expect(center.results[shop.id]?.status == .failed && after == before, "同路径应用替换时不向苹果发送旧标识")
        print("商店与更新列表：\(count) 项检查通过")
    }
}

#if UPDATE_CENTER_STANDALONE_TESTS
@main enum UpdateCenterTestMain { static func main() async throws { try await UpdateCenterChecks.run() } }
#else
final class UpdateCenterTests: XCTestCase { func testUpdateCenter() async throws { try await UpdateCenterChecks.run() } }
#endif
