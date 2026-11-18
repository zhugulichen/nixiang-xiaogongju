import Foundation
import Security
import SQLite3
#if !PRIVACY_STANDALONE_TESTS
import XCTest
@testable import CleanCore
#endif

private enum PrivacyChecks {
    struct Failure: Error { var detail: String }
    final class Calls: @unchecked Sendable { var arguments: [[String]] = [] }

    static func sql(_ path: URL, _ text: String) throws {
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        guard sqlite3_open(path.path, &db) == SQLITE_OK, sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
            throw Failure(detail: db.map { String(cString: sqlite3_errmsg($0)) } ?? "未创建自建资料库")
        }
    }

    static func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("qingzhou-permissions-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("Fixture.app")
        let contents = bundle.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let identifier = "org.example.PrivacyFixture"
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        let plist = contents.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: plist)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let signing = Process(); signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", "--timestamp=none", bundle.path]; signing.standardError = FileHandle.nullDevice
        try signing.run(); signing.waitUntilExit()
        guard signing.terminationStatus == 0 else { throw Failure(detail: "签名测试应用失败") }
        var code: SecStaticCode?, rule: SecRequirement?, bytes: CFData?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &rule) == errSecSuccess, let rule,
              SecRequirementCopyData(rule, [], &bytes) == errSecSuccess, let bytes else { throw Failure(detail: "未读取到自建应用签名条件") }
        let binary = bytes as Data
        let hex = binary.map { String(format: "%02x", $0) }.joined()
        let app = AppRecord(url: bundle, name: "测试", bundleID: identifier, version: "1")
        let user = root.appendingPathComponent("user.db"), system = root.appendingPathComponent("system.db")
        let schema = "CREATE TABLE access(service TEXT,client TEXT,client_type INTEGER,auth_value INTEGER,auth_reason INTEGER,csreq BLOB,indirect_object_identifier TEXT,policy_id INTEGER,last_modified INTEGER)"
        try sql(user, schema); try sql(system, schema)
        func add(_ service: String, value: Int = 2, reason: Int = 2, target: String = "UNUSED", db: URL? = nil,
                 client: String? = nil, clientType: Int = 0, data: String? = nil, policy: String = "NULL") throws {
            try sql(db ?? user, "INSERT INTO access VALUES ('kTCCService\(service)','\(client ?? identifier)',\(clientType),\(value),\(reason),\(data ?? "X'" + hex + "'"),'\(target)',\(policy),1)")
        }
        try add("Camera"); try add("Microphone", value: 0); try add("Photos", value: 3)
        try add("AppleEvents", target: "org.example.TargetA"); try add("AppleEvents", target: "org.example.TargetB")
        try add("SystemPolicyAllFiles", db: system)
        try add("Reminders", value: 1); try add("ContactsUnknown", value: 32)
        try add("Calendar", data: "X'00'"); try add("HomeKit", data: "NULL")
        try add("ListenEvent", policy: "12"); try add("Siri", reason: 4)
        try add("Accessibility", client: bundle.path, clientType: 1)
        try add("Motion", client: identifier + ".other")
        let calls = Calls()
        let audit = PrivacyAccessService(databases: [user, system], match: { PrivacyAccessService.matchesCode(at: $0, identifier: $1, requirement: $2) }, reset: { service, id in
            calls.arguments.append([service, id])
            guard service == "Camera", id == identifier else { throw Failure(detail: "操作范围错误") }
            try sql(user, "DELETE FROM access WHERE service = 'kTCCServiceCamera' AND client = 'org.example.PrivacyFixture'")
        })
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(detail: message) }
            print("通过：" + message); count += 1
        }
        func rejects(_ operation: () throws -> Void) -> Bool {
            do { try operation(); return false } catch { return true }
        }
        let report = audit.inspect(app)
        let groups = Dictionary(uniqueKeysWithValues: report.groups.map { ($0.id, $0) })
        try check(report.warnings.isEmpty && groups.count == 12, "只查询所选应用标识与确切路径")
        guard let camera = groups["Camera"] else { throw Failure(detail: "缺少相机记录") }
        try check(camera.records.first?.status == "已允许" && camera.allowsReset, "真实签名条件匹配后允许单项撤销")
        try check(groups["Microphone"]?.records.first?.status == "已拒绝" && groups["Microphone"]?.allowsReset == false, "区分已拒绝和可撤销授权")
        try check(groups["Photos"]?.records.first?.status == "有限授权" && groups["Photos"]?.allowsReset == true, "有限照片授权可单独重置")
        try check(groups["Reminders"]?.records.first?.status == "待决定", "尚待决定独立显示")
        try check(groups["SystemPolicyAllFiles"]?.records.first?.source == "全机", "全机与用户决定来源分开")
        try check(groups["AppleEvents"]?.records.compactMap(\.target) == ["org.example.TargetA", "org.example.TargetB"], "自动控制的多个目标归在同一服务")
        try check(groups["Calendar"]?.records.first?.status == "当前授权未核实" && groups["Calendar"]?.allowsReset == false, "签名条件不匹配后停止操作")
        try check(groups["HomeKit"]?.allowsReset == false && groups["HomeKit"]?.records.first?.status == "当前授权未核实", "缺少签名证据时保留未知状态")
        try check(groups["ContactsUnknown"]?.allowsReset == false && groups["ContactsUnknown"]?.records.first?.status == "未知授权值", "未知权限和决定值仅供查看")
        try check(groups["Siri"]?.allowsReset == false && groups["ListenEvent"]?.allowsReset == false, "受管权限和系统决定受保护")
        try check(groups["Accessibility"]?.allowsReset == false, "按路径登记的决定不会交给按标识的重置命令")
        let protectedSystem = PrivacyAccessService(databases: [user, system], match: { _, _, _ in
            preconditionFailure("新系统不得读取旧授权库")
        }, reset: { _, _ in
            preconditionFailure("清舟应转到系统设置处理")
        }, operatingSystemMajorVersion: 27)
        let protectedReport = protectedSystem.inspect(app)
        try check(protectedReport.requiresSystemSettings && protectedReport.groups.isEmpty && protectedReport.warnings.isEmpty,
                  "系统禁止直接读取时返回独立的系统设置状态")
        try check(rejects { _ = try protectedSystem.revoke(camera, for: app) }, "新系统拒绝重放旧界面的撤销决定")
        try sql(user, "UPDATE access SET last_modified = 2 WHERE service = 'kTCCServiceCamera'")
        try check(rejects { _ = try audit.revoke(camera, for: app) } && calls.arguments.isEmpty, "确认后决定已变化时中止")
        let refreshed = audit.inspect(app)
        guard let fresh = refreshed.groups.first(where: { $0.id == "Camera" }) else { throw Failure(detail: "未找到最新相机记录") }
        let after = try audit.revoke(fresh, for: app)
        try check(calls.arguments == [["Camera", identifier]] && !after.groups.contains(where: { $0.id == "Camera" }) && after.groups.contains(where: { $0.id == "Photos" }), "精确调用一个应用的一个服务并复查")
        let missing = root.appendingPathComponent("absent.db")
        let other = PrivacyAccessService(databases: [missing, system], match: { _, _, _ in true }, reset: { _, _ in })
        let partial = other.inspect(app)
        try check(!partial.requiresSystemSettings && partial.warnings.count == 1 && partial.warnings.first?.contains("未找到") == true &&
                  partial.groups.count == 1 && !fm.fileExists(atPath: missing.path),
                  "旧系统区分缺失记录库和授权拒绝，保留可读部分")
        let old = root.appendingPathComponent("old.db"); try sql(old, "CREATE TABLE access(service, client, allowed)")
        try check(PrivacyAccessService(databases: [old], match: { _,_,_ in true }, reset: { _,_ in }).inspect(app).warnings.count == 1, "未知系统结构不会被当成无权限")
        try sql(system, "DELETE FROM access"); try sql(user, "DELETE FROM access")
        let empty = audit.inspect(app)
        try check(empty.groups.isEmpty && empty.warnings.isEmpty, "没有记录与权限不足分开")
        let forged = AppRecord(url: bundle, name: "测试", bundleID: "All", version: "1")
        try check(!audit.inspect(forged).warnings.isEmpty && rejects { _ = try audit.revoke(fresh, for: forged) }, "无有效应用身份绝不重置")
        print("逐应用隐私权限：\(count) 项检查通过")
    }
}

#if PRIVACY_STANDALONE_TESTS
@main enum PrivacyStandalone { static func main() throws { try PrivacyChecks.run() } }
#else
final class PrivacyAccessTests: XCTestCase { func testScopedPrivacyDecisions() throws { try PrivacyChecks.run() } }
#endif
