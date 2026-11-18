import Foundation
#if !GROUPS_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private enum GroupChecks {
    struct Failure: Error { let detail: String }

    static func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("qingzhou-groups-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ ok: Bool, _ title: String) throws {
            guard ok else { throw Failure(detail: title) }
            checks += 1; print("通过：" + title)
        }
        let appID = "org.example.GroupFixture", team = "ABCDE12345"
        let group = "group.org.example.Suite", teamGroup = team + ".suite-shared"
        let eligible = ApplicationGroupService.eligibleGroups
        try check(eligible([group, teamGroup, group, "FFFFF12345.suite"], team) == [group, teamGroup], "注册组和本团队组去重，排除不同团队前缀")
        try check(eligible(["group.com.apple.notes", team + ".com.apple.Files", "group.cn.local.qingzhou.helper", "group.APPLE.mail"], team).isEmpty, "苹果和清舟保留标识不计为候选")
        try check(eligible(["group.", "group..foo", "group.foo/../../private", "group.foo.", "group.test%2Ffoo", "group.\u{0}x", "other.example.foo", "group." + String(repeating: "a", count: 251)], team).isEmpty, "拒绝越界、超长和格式无效标识")
        try check(eligible([group], "short").isEmpty && eligible(Array(repeating: group, count: 129), team).isEmpty, "缺少合法团队或声明数量超限时不采信")

        let host = root.appendingPathComponent("Fixture.app")
        let plugin = host.appendingPathComponent("Contents/PlugIns")
        let foreign = root.appendingPathComponent("Foreign.appex")
        for url in [plugin.appendingPathComponent("Viewer.appex"), plugin.appendingPathComponent("WrongTeam.appex"), plugin.appendingPathComponent("Unrelated.appex"), plugin.appendingPathComponent("nested/Hidden.appex"), foreign] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: plugin.appendingPathComponent("External.appex"), withDestinationURL: foreign)
        typealias Declaration = ApplicationGroupService.Declaration
        var visits = Set<String>()
        func read(_ url: URL) -> Declaration? {
            visits.insert(url.lastPathComponent)
            switch url.lastPathComponent {
            case "Fixture.app", "Inside.app": return Declaration(identifier: appID, team: team, groups: [group])
            case "Viewer.appex": return Declaration(identifier: appID + ".viewer", team: team, groups: [teamGroup])
            case "WrongTeam.appex": return Declaration(identifier: appID + ".wrong", team: "FFFFF12345", groups: ["group.foreign"])
            default: return Declaration(identifier: "com.example.unrelated", team: team, groups: ["group.unrelated"])
            }
        }
        func groups(_ app: URL, _ expected: String = appID) -> Set<String> {
            ApplicationGroupService.declaredIdentifiers(at: app, expectedBundleID: expected, read: read)
        }
        try check(groups(host) == [group, teamGroup], "同团队直属扩展加入归属；无关签名标识与异团队不混入")
        try check(visits.isDisjoint(with: ["Hidden.appex", "External.appex"]), "不读取外部链接和更深层的扩展")
        try check(groups(host, "org.example.unrelated").isEmpty, "扫描期应用身份不一致返回空集合")
        let alias = root.appendingPathComponent("Alias.app")
        try fm.createSymbolicLink(at: alias, withDestinationURL: host)
        try check(groups(alias).isEmpty, "应用本体符号链接不参与读取")
        let wrapped = root.appendingPathComponent("Mobile.app")
        let inner = wrapped.appendingPathComponent("Wrapper/Inside.app")
        try fm.createDirectory(at: inner.appendingPathComponent("PlugIns/Viewer.appex"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: wrapped.appendingPathComponent("WrappedBundle").path, withDestinationPath: "Wrapper/Inside.app")
        try check(groups(wrapped) == [group, teamGroup], "受限内部包装路径可识别主程序与扩展")

        let parent = root.appendingPathComponent("Library/Group Containers")
        let wanted = parent.appendingPathComponent(group)
        let lookalike = parent.appendingPathComponent(group + "-different")
        for url in [wanted, lookalike] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let linked = parent.appendingPathComponent(teamGroup)
        try fm.createSymbolicLink(at: linked, withDestinationURL: wanted)
        let text = "group.only-a-file"
        try Data().write(to: parent.appendingPathComponent(text))
        let candidates = ApplicationGroupService.containerURLs(for: [group, teamGroup, group.lowercased(), text, "group.missing"], home: root)
        try check(candidates.map(\.path) == [wanted.path], "只返回确切大小写及真实直接子目录，排除同前缀、链接和普通文件")
        let fromTemporaryAlias = ApplicationGroupService.containerURLs(for: [group], home: root.standardizedFileURL)
        try check(fromTemporaryAlias.map(\.lastPathComponent) == [group], "系统临时路径规范化后仍可识别真实组目录")
        try check(!fm.fileExists(atPath: parent.appendingPathComponent("group.missing").path), "只读匹配不会创建缺失容器")
        let aliasHome = root.appendingPathComponent("AliasHome")
        try fm.createSymbolicLink(at: aliasHome, withDestinationURL: root)
        try check(ApplicationGroupService.containerURLs(for: [group], home: aliasHome).isEmpty, "父目录符号链接不产生清理候选")

        // Sign only our disposable fixture, using no identity or keychain certificate.
        let fixture = root.appendingPathComponent("AdHoc.app"), contents = fixture.appendingPathComponent("Contents")
        let bin = contents.appendingPathComponent("MacOS/Fixture")
        try fm.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: bin)
        func writePlist(_ dict: [String: Any], _ url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        }
        try writePlist(["CFBundleIdentifier": appID, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"], contents.appendingPathComponent("Info.plist"))
        let rights = root.appendingPathComponent("fixture-entitlements.plist")
        try writePlist(["com.apple.security.application-groups": [group, teamGroup], "com.apple.developer.team-identifier": team], rights)
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--timestamp=none", "--entitlements", rights.path, fixture.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        try check(sign.terminationStatus == 0 && ApplicationGroupService.declaredIdentifiers(at: fixture, expectedBundleID: appID).isEmpty, "自建临时签名伪声明不能冒充开发者身份")
        print("签名共享容器：\(checks) 项检查通过")
    }
}

#if GROUPS_STANDALONE_TESTS
@main enum GroupTestMain { static func main() throws { try GroupChecks.run() } }
#else
final class ApplicationGroupTests: XCTestCase { func testSignedGroups() throws { try GroupChecks.run() } }
#endif
