import Foundation
#if !PROTECTION_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private enum ProtectionChecks {
    static func run() throws {
        let root = URL(fileURLWithPath: "/Users/example/Library/Caches/org.example.demo")
        let record = SkippedApplication(bundleID: "org.example.demo", name: "示例应用",
            relatedIdentifiers: ["org.example.helper"], paths: [root])
        let policy = ApplicationProtectionPolicy(records: [record])
        let cases: [(String, () throws -> Void)] = [
            ("名单及已核对关联证据可以持久保存", {
                let encoded = try ApplicationProtectionPolicy.encode([record])
                let decoded = try ApplicationProtectionPolicy.decode(encoded)
                precondition(decoded == [record])
                let empty = try ApplicationProtectionPolicy.decode(nil)
                precondition(empty.isEmpty)
            }),
            ("完整应用和辅助标识受保护但相似前缀不受影响", {
                for identifier in ["org.example.demo", "org.example.helper"] {
                    let file = CleanFile(url: URL(fileURLWithPath: "/Users/example/Library/Logs/new"), kind: .logs, reason: "测试", ownerBundleID: identifier)
                    precondition(policy.isBlocked(file))
                }
                let sibling = CleanFile(url: URL(fileURLWithPath: "/Users/example/Library/Logs/new"), kind: .logs, reason: "测试", ownerBundleID: "org.example.demolition")
                precondition(!policy.isBlocked(sibling))
            }),
            ("共享路径及父子重叠受保护且不误伤同名前缀", {
                for path in [root, root.appendingPathComponent("child"), root.deletingLastPathComponent()] {
                    precondition(policy.isBlocked(CleanFile(url: path, kind: .cache, reason: "测试")))
                }
                let sibling = URL(fileURLWithPath: root.path + "-other")
                precondition(!policy.isBlocked(CleanFile(url: sibling, kind: .cache, reason: "测试")))
            }),
            ("应用本体不能用伪造归属绕过名单", {
                let file = CleanFile(url: URL(fileURLWithPath: "/Applications/Other Copy.app"), kind: .application, reason: "测试")
                var denied = false
                do { try policy.validate(file, actualBundleID: "org.example.demo") } catch { denied = true }
                precondition(denied)
            }),
            ("保护显示取消默认选择且保留未受影响项目", {
                let protected = CleanFile(url: root, kind: .cache, reason: "原始证据", defaultSelected: true)
                let other = CleanFile(url: URL(fileURLWithPath: root.path + "-other"), kind: .cache, reason: "其他", defaultSelected: true)
                let output = policy.applying(to: [protected, other])
                precondition(output[0].risk == .protected && !output[0].defaultSelected)
                precondition(output[0].reason.contains("跳过名单"))
                precondition(output[1] == other)
            }),
            ("应用已不在磁盘上仍保留关联保护", {
                precondition(!FileManager.default.fileExists(atPath: root.path))
                precondition(policy.isBlocked(CleanFile(url: root, kind: .cache, reason: "测试")))
            }),
            ("损坏或不安全名单不会被悄悄当作空名单", {
                for data in [Data("broken".utf8), Data("[{\"bundleID\":\"\",\"name\":\"bad\",\"relatedIdentifiers\":[],\"paths\":[]}]".utf8)] {
                    var denied = false
                    do { _ = try ApplicationProtectionPolicy.decode(data) } catch { denied = true }
                    precondition(denied)
                }
            }),
            ("设置读取失败时停止所有清理", {
                let invalid = ApplicationProtectionPolicy(records: [], configurationError: "名单损坏")
                let file = CleanFile(url: root, kind: .cache, reason: "测试")
                precondition(invalid.isBlocked(file))
                var denied = false
                do { try invalid.validate(file) } catch { denied = true }
                precondition(denied)
            }),
            ("已有设置类型错误不能当作未设置", {
                for value: Any in ["broken", ["org.example.demo"], 42] {
                    var denied = false
                    do { _ = try ApplicationProtectionPolicy.decodePreference(value) } catch { denied = true }
                    precondition(denied)
                }
                let absent = try ApplicationProtectionPolicy.decodePreference(nil)
                precondition(absent.isEmpty)
            }),
            ("新产生的三类更新缓存仍归入精确保护范围", {
                let minimal = ApplicationProtectionPolicy(records: [SkippedApplication(bundleID: "org.example.demo", name: "示例")])
                for suffix in [".ShipIt", ".sparkle", ".Squirrel"] {
                    let url = URL(fileURLWithPath: "/Users/example/Library/Caches/org.example.demo" + suffix)
                    let cachePage = CleanFile(url: url, kind: .cache, reason: "新更新缓存", ownerBundleID: url.lastPathComponent)
                    precondition(minimal.isBlocked(cachePage))
                    let other = CleanFile(url: URL(fileURLWithPath: "/Users/example/Library/Caches/org.example.demolition" + suffix), kind: .cache, reason: "不同应用")
                    precondition(!minimal.isBlocked(other))
                }
            })
        ]
        for (name, test) in cases { try test(); print("通过：" + name) }
        print("全局跳过名单：\(cases.count) 项检查通过")
    }
}

#if PROTECTION_STANDALONE_TESTS
@main enum ApplicationProtectionTestMain { static func main() throws { try ProtectionChecks.run() } }
#else
final class ApplicationProtectionTests: XCTestCase { func testProtectionChecks() throws { try ProtectionChecks.run() } }
#endif
