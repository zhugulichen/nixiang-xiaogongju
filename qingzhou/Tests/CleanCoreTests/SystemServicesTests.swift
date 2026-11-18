#if SYSTEM_STANDALONE_TESTS
import Foundation
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a == b, "断言失败：\(a) != \(b)", file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "应为空值", file: file, line: line)
}
func XCTAssertThrowsError<T>(_ action: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try action(); preconditionFailure("预期错误未发生", file: file, line: line) } catch {}
}
func XCTAssertNoThrow<T>(_ action: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try action() } catch { preconditionFailure("意外错误：\(error)", file: file, line: line) }
}
#else
import XCTest
@testable import CleanCore
#endif

final class SystemServicesTests: XCTestCase {
    private let source = URL(string: "https://example.org/updates.xml")!
    private var app: AppRecord {
        AppRecord(url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "测试", bundleID: "org.example.fixture", version: "2.9", feedURL: source)
    }

    func testVersionOrderingUsesNumbersAndIgnoresTrailingZeroes() {
        XCTAssertEqual(UpdateService.compareVersions("2.10", "2.9"), .orderedDescending)
        XCTAssertEqual(UpdateService.compareVersions("v2.9.0", "2.9"), .orderedSame)
        XCTAssertEqual(UpdateService.compareVersions("12.0.1", "12.0"), .orderedDescending)
    }

    func testModernFeedUsesDisplayVersionAndFiltersPrereleaseAndOtherOS() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:version>900</sparkle:version><sparkle:shortVersionString>9.0</sparkle:shortVersionString><sparkle:channel>beta</sparkle:channel></item>
          <item><sparkle:version>800</sparkle:version><sparkle:shortVersionString>8.0</sparkle:shortVersionString><enclosure url="https://example.org/windows.exe" sparkle:os="windows" /></item>
          <item><sparkle:version>700</sparkle:version><sparkle:shortVersionString>7.0</sparkle:shortVersionString><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
          <item><title>Version 6.0 RC 1</title><sparkle:version>600</sparkle:version><sparkle:shortVersionString>6.0</sparkle:shortVersionString></item>
          <item><sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0b1</sparkle:shortVersionString></item>
          <item><sparkle:version>2100</sparkle:version><sparkle:shortVersionString>2.10</sparkle:shortVersionString><link>https://example.org/product</link><enclosure url="https://example.org/download.zip" /></item>
        </channel></rss>
        """
        let result = try parseInstalledXML(xml, systemVersion: "27.0")
        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.latestVersion, "2.10")
        XCTAssertEqual(result.url?.absoluteString, "https://example.org/product")
    }

    func testLegacyFeedAndDeltaCannotReplaceFullDownload() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <enclosure url="https://example.org/full.zip" sparkle:version="290" sparkle:shortVersionString="2.9.0" />
        <sparkle:deltas><enclosure url="https://example.org/delta.zip" sparkle:version="999" sparkle:shortVersionString="99.0" /></sparkle:deltas>
        </item></channel></rss>
        """
        let result = try parseInstalledXML(xml, build: "290")
        XCTAssertEqual(result.status, .upToDate)
        XCTAssertEqual(result.latestVersion, "2.9.0")
        XCTAssertEqual(result.url?.absoluteString, "https://example.org/full.zip")
    }

    func testEmptyIncompatibleAndInvalidFeedsDoNotClaimUpToDate() throws {
        let empty = try checkInstalledFeed("")
        XCTAssertEqual(empty.status, .failed)
        XCTAssertThrowsError(try UpdateService.parseFeed(Data("<rss>".utf8), app: app, sourceURL: source))
        let unsafe = "<!DOCTYPE rss [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><rss>&e;</rss>"
        XCTAssertThrowsError(try UpdateService.parseFeed(Data(unsafe.utf8), app: app, sourceURL: source))
    }

    func testInsecureLinkIsNotReturned() throws {
        let xml = "<rss><channel><item><version>3.0</version><link>http://example.org/unsafe</link></item></channel></rss>"
        let result = try parseInstalledXML(xml, build: "2.9")
        XCTAssertEqual(result.status, .available)
        XCTAssertNil(result.url)
    }

    func testDisabledOutputParsesBothCurrentAndLegacyFormats() {
        let parsed = SystemServices.parseDisabled("\"org.example.one\" => disabled\n\"org.example.two\" => enabled\n\"org.example.three\" => true\n\"org.example.four\" => false")
        XCTAssertEqual(parsed["org.example.one"], true)
        XCTAssertEqual(parsed["org.example.two"], false)
        XCTAssertEqual(parsed["org.example.three"], true)
        XCTAssertEqual(parsed["org.example.four"], false)
    }

    func testStartupMutationRejectsSystemEntryBeforeExecuting() {
        let entry = StartupEntry(url: URL(fileURLWithPath: "/Library/LaunchDaemons/org.example.fixture.plist"), label: "org.example.fixture", name: "测试", isEnabled: true, canToggle: true, detail: "")
        XCTAssertThrowsError(try SystemServices().setEnabled(false, for: entry))
    }

    @MainActor func testDefaultApplicationRejectsPathAndUnknownExtension() {
        XCTAssertThrowsError(try DefaultAppService.defaultApplication(forExtension: "../../etc/passwd"))
        XCTAssertThrowsError(try DefaultAppService.defaultApplication(forExtension: ""))
        XCTAssertNoThrow(try DefaultAppService.defaultApplication(forExtension: ".pdf"))
    }

    func testMissingUpdateSourceDoesNotUseNetwork() async {
        let app = AppRecord(url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "测试", bundleID: "org.example.fixture", version: "1.0")
        let result = await UpdateService.check(app: app)
        XCTAssertEqual(result.status, .noSource)
    }

    func testFeedBuildNumberComparedToInstalledBuildNumber() throws {
        let result = try checkInstalledFeed("<item><version>299</version><link>https://example.org/app</link></item>")
        XCTAssertEqual(result.status, .upToDate)
    }

    private func checkInstalledFeed(_ items: String, build: String? = "300", identifier: String = "org.example.buildfixture") throws -> UpdateInfo {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        \(items)
        </channel></rss>
        """
        return try parseInstalledXML(xml, build: build, identifier: identifier)
    }

    private func parseInstalledXML(_ xml: String, build: String? = "300", identifier: String = "org.example.buildfixture",
                                   systemVersion: String = "27.0") throws -> UpdateInfo {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var plist = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "2.9"]
        plist["CFBundleVersion"] = build
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let record = AppRecord(url: directory, name: "测试", bundleID: "org.example.buildfixture", version: "2.9")
        return try UpdateService.parseFeed(Data(xml.utf8), app: record, sourceURL: source, systemVersion: systemVersion)
    }

    func testSameDisplayVersionPicksNewestBuildRegardlessOfFeedOrder() throws {
        let old = "<item><version>300</version><shortVersionString>2.9</shortVersionString><link>current</link></item>"
        let new = "<item><version>302</version><shortVersionString>2.9</shortVersionString><link>hotfix</link></item>"
        for items in [old + new, new + old] {
            let result = try checkInstalledFeed(items)
            XCTAssertEqual(result.status, .available)
            XCTAssertEqual(result.url?.lastPathComponent, "hotfix")
            XCTAssertEqual(result.message.contains("302"), true)
        }
        let oldBuild = try checkInstalledFeed("<item><version>299</version><shortVersionString>3.0</shortVersionString></item>")
        XCTAssertEqual(oldBuild.status, .upToDate)
    }

    func testNestedInformationalVersionsCannotReplaceReleaseMetadata() throws {
        let result = try checkInstalledFeed("""
        <item><sparkle:version>302</sparkle:version><link>product</link>
        <sparkle:informationalUpdate><sparkle:version>298</sparkle:version></sparkle:informationalUpdate>
        <description><link>unrelated</link></description>
        <sparkle:deltas><enclosure url="delta.zip" sparkle:version="999" /></sparkle:deltas></item>
        """)
        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.latestVersion, "302")
        XCTAssertEqual(result.url?.lastPathComponent, "product")
    }

    func testMinimumInstalledBuildSelectsIntermediateVersion() throws {
        let items = """
        <item><version>400</version><shortVersionString>4.0</shortVersionString><minimumUpdateVersion>350</minimumUpdateVersion></item>
        <item><version>350</version><shortVersionString>3.5</shortVersionString><minimumUpdateVersion>300</minimumUpdateVersion></item>
        """
        XCTAssertEqual(try checkInstalledFeed(items).latestVersion, "3.5")
        XCTAssertEqual(try checkInstalledFeed(items, build: "350").latestVersion, "4.0")
        XCTAssertEqual(try checkInstalledFeed(items, build: nil).status, .failed)
    }

    func testBuildOnlyFeedNeedsMatchingLocalBuild() throws {
        let items = "<item><version>302</version><link>product</link></item>"
        XCTAssertEqual(try checkInstalledFeed(items, build: nil).status, .failed)
        XCTAssertEqual(try checkInstalledFeed(items, identifier: "org.example.replaced").status, .failed)
    }

    func testHardwareRequirementMatchesWholeArchitectureNames() throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let template = "<item><version>310</version><hardwareRequirements>%@</hardwareRequirements></item>"
        XCTAssertEqual(try checkInstalledFeed(String(format: template, architecture.uppercased())).status, .available)
        XCTAssertEqual(try checkInstalledFeed(String(format: template, "not-" + architecture)).status, .failed)
    }

    func testLegacyPackageMetadataOverridesItemDefaultsForThatPackage() throws {
        let result = try checkInstalledFeed("""
        <item><version>298</version><shortVersionString>2.8</shortVersionString>
        <enclosure url="full.zip" sparkle:version="301" sparkle:shortVersionString="2.9" />
        </item>
        """)
        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.latestVersion, "2.9")
        XCTAssertEqual(result.url?.lastPathComponent, "full.zip")
    }

    func testStartupDomainsSeparateSystemDaemonsFromUserAgents() {
        XCTAssertEqual(SystemServices.startupDomain(for: URL(fileURLWithPath: "/Library/LaunchDaemons"), userID: 501), "system")
        XCTAssertEqual(SystemServices.startupDomain(for: URL(fileURLWithPath: "/System/Library/LaunchDaemons"), userID: 501), "system")
        XCTAssertEqual(SystemServices.startupDomain(for: URL(fileURLWithPath: "/Library/LaunchAgents"), userID: 501), "gui/501")
        XCTAssertEqual(SystemServices.startupDomain(for: URL(fileURLWithPath: "/Users/fixture/Library/LaunchAgents"), userID: 502), "gui/502")
    }

    func testCurrentAndLegacySelfLabelsAreProtectedWithComponentBoundary() {
        for label in ["cn.local.qingzhou", "cn.local.qingzhou.monitor", "com.qingzhou.cleaner", "com.apple.Finder"] {
            XCTAssertEqual(SystemServices.isProtectedLabel(label), true)
        }
        XCTAssertEqual(SystemServices.isProtectedLabel("cn.local.qingzhouunrelated"), false)
        XCTAssertEqual(SystemServices.isProtectedLabel("org.example.fixture"), false)
    }

    func testMultipleEnclosuresChooseCompatibleMacVersionRegardlessOfOrder() throws {
        let mac = "<enclosure url=\"https://example.org/mac.zip\" sparkle:version=\"210\" sparkle:shortVersionString=\"2.10\" sparkle:os=\"macos\" />"
        let windows = "<enclosure url=\"https://example.org/windows.exe\" sparkle:version=\"900\" sparkle:shortVersionString=\"9.0\" sparkle:os=\"windows\" />"
        let delta = "<enclosure url=\"https://example.org/delta.zip\" sparkle:version=\"999\" sparkle:shortVersionString=\"99.0\" sparkle:deltaFrom=\"1\" />"
        for enclosures in [[mac, windows, delta], [windows, delta, mac]] {
            let xml = "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item>" + enclosures.joined() + "</item></channel></rss>"
            let result = try parseInstalledXML(xml, build: "209")
            XCTAssertEqual(result.status, .available)
            XCTAssertEqual(result.latestVersion, "2.10")
            XCTAssertEqual(result.url?.absoluteString, "https://example.org/mac.zip")
        }
    }

    func testNetworkTimeoutNeverReportsUpToDate() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeoutUpdateProtocol.self]
        let result = await UpdateService.check(app: app, configuration: configuration)
        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.latestVersion)
        XCTAssertNil(result.url)
        XCTAssertEqual(result.message.contains("超时"), true)
        XCTAssertEqual(result.message.contains("尚未确认"), true)
    }
}

private final class TimeoutUpdateProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    override func stopLoading() {}
}

#if SYSTEM_STANDALONE_TESTS
@main struct SystemServicesTestRunner {
    @MainActor static func main() async throws {
        let tests = SystemServicesTests()
        tests.testVersionOrderingUsesNumbersAndIgnoresTrailingZeroes()
        try tests.testModernFeedUsesDisplayVersionAndFiltersPrereleaseAndOtherOS()
        try tests.testLegacyFeedAndDeltaCannotReplaceFullDownload()
        try tests.testEmptyIncompatibleAndInvalidFeedsDoNotClaimUpToDate()
        try tests.testInsecureLinkIsNotReturned()
        tests.testDisabledOutputParsesBothCurrentAndLegacyFormats()
        tests.testStartupMutationRejectsSystemEntryBeforeExecuting()
        tests.testDefaultApplicationRejectsPathAndUnknownExtension()
        await tests.testMissingUpdateSourceDoesNotUseNetwork()
        try tests.testFeedBuildNumberComparedToInstalledBuildNumber()
        tests.testStartupDomainsSeparateSystemDaemonsFromUserAgents()
        tests.testCurrentAndLegacySelfLabelsAreProtectedWithComponentBoundary()
        try tests.testMultipleEnclosuresChooseCompatibleMacVersionRegardlessOfOrder()
        await tests.testNetworkTimeoutNeverReportsUpToDate()
        try tests.testSameDisplayVersionPicksNewestBuildRegardlessOfFeedOrder()
        try tests.testNestedInformationalVersionsCannotReplaceReleaseMetadata()
        try tests.testMinimumInstalledBuildSelectsIntermediateVersion()
        try tests.testBuildOnlyFeedNeedsMatchingLocalBuild()
        try tests.testLegacyPackageMetadataOverridesItemDefaultsForThatPackage()
        try tests.testHardwareRequirementMatchesWholeArchitectureNames()
        print("系统管理模块：20 项测试通过")
    }
}
#endif
