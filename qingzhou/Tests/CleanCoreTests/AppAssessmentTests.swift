#if ASSESSMENT_STANDALONE_TESTS
import Foundation
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a == b, "断言失败：\(a) != \(b)", file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "应为空值", file: file, line: line)
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "应为真值", file: file, line: line)
}
#else
import XCTest
@testable import CleanCore
#endif

final class AppAssessmentTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/Applications/测试 application.app")
    private func command(_ code: Int32 = 0, output: String = "", error: String = "") -> AssessmentCommandResult {
        .init(completion: .exited, exitCode: code, stdout: output, stderr: error)
    }
    private func policy(_ accepted: Bool, source: String? = nil) throws -> AssessmentCommandResult {
        var authority: [String: Any] = [:]
        if let source { authority["assessment:authority:source"] = source }
        let value: [String: Any] = ["assessment:verdict": accepted, "assessment:authority": authority]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        return command(accepted ? 0 : 3, output: String(decoding: data, as: UTF8.self))
    }
    private var signedMetadata: AssessmentCommandResult {
        command(error: "Executable=/Applications/测试 application.app/Contents/MacOS/Test\nIdentifier=org.example.test\nAuthority=Developer ID Application: Example\nAuthority=Apple Root CA\nTeamIdentifier=EXAMPLE123\n")
    }
    private func assessment(_ display: AssessmentCommandResult? = nil, verification: AssessmentCommandResult? = nil,
                            policy: AssessmentCommandResult) -> AppAssessment {
        AppAssessmentService.interpret(url: url, display: display ?? signedMetadata,
                                       verification: verification ?? command(), policyResult: policy)
    }

    func testNotarizationRequiresPositiveSystemVerdict() throws {
        let positive = assessment(policy: try policy(true, source: "Notarized Developer ID"))
        XCTAssertEqual(positive.signature, .valid)
        XCTAssertEqual(positive.policy, .accepted)
        XCTAssertEqual(positive.notarization, .confirmed)
        XCTAssertEqual(positive.signer, "Developer ID Application: Example")
        XCTAssertEqual(positive.teamIdentifier, "EXAMPLE123")
        let rejected = assessment(policy: try policy(false, source: "Notarized Developer ID"))
        XCTAssertEqual(rejected.policy, .rejected)
        XCTAssertEqual(rejected.notarization, .unconfirmed)
    }
    func testAdHocIsDistinctFromTrustedDeveloper() throws {
        let metadata = command(error: "Executable=/Applications/Local.app/Contents/MacOS/Test\nIdentifier=org.example.local\nSignature=adhoc\nTeamIdentifier=not set\n")
        let result = assessment(metadata, policy: try policy(false))
        XCTAssertEqual(result.signature, .adHoc)
        XCTAssertEqual(result.notarization, .unconfirmed)
        XCTAssertNil(result.signer)
        XCTAssertNil(result.teamIdentifier)
    }
    func testUnsignedAndTamperedAreDistinct() throws {
        let unsigned = command(1, error: "\(url.path): code object is not signed at all\n")
        XCTAssertEqual(assessment(unsigned, verification: unsigned, policy: try policy(false)).signature, .unsigned)
        let invalid = command(1, error: "\(url.path): a sealed resource is missing or invalid\n")
        XCTAssertEqual(assessment(verification: invalid, policy: try policy(false)).signature, .invalid)
    }
    func testUnsignedNestedCodeFailsSignedApplicationIntegrity() throws {
        let nested = command(1, error: "\(url.path): code object is not signed at all\nIn subcomponent: helper")
        XCTAssertEqual(assessment(verification: nested, policy: try policy(false)).signature, .invalid)
    }
    func testPathNewlineCannotInjectSigningMetadata() throws {
        let metadata = command(error: "Executable=/Applications/Injected\nIdentifier=fake\nAuthority=Fake Signer\nSignature=adhoc\n.app/Contents/MacOS/Test\nIdentifier=org.example.real\nAuthority=Real Signer\nTeamIdentifier=REALTEAM\n")
        let result = assessment(metadata, policy: try policy(true))
        XCTAssertEqual(result.signature, .valid)
        XCTAssertEqual(result.signer, "Real Signer")
        XCTAssertEqual(result.teamIdentifier, "REALTEAM")
    }
    func testOfflineAndPermissionErrorsRemainIndeterminate() {
        let denied = command(1, error: "Operation not permitted")
        let offline = command(1, error: "The network connection is offline.")
        let result = assessment(verification: denied, policy: offline)
        XCTAssertEqual(result.signature, .indeterminate)
        XCTAssertEqual(result.policy, .indeterminate)
        XCTAssertEqual(result.notarization, .unconfirmed)
    }
    func testTimeoutDoesNotReportNoNotarization() {
        let timeout = AssessmentCommandResult(completion: .timedOut, exitCode: 0, stdout: "", stderr: "")
        let result = assessment(verification: timeout, policy: timeout)
        XCTAssertEqual(result.signature, .indeterminate)
        XCTAssertEqual(result.policy, .indeterminate)
        XCTAssertEqual(result.notarization, .unconfirmed)
        XCTAssertTrue(result.detail.contains("超时"))
    }
    func testAppleAndStoreDoNotNeedStandaloneNotarization() throws {
        for source in ["Apple System", "Mac App Store"] {
            XCTAssertEqual(assessment(policy: try policy(true, source: source)).notarization, .notRequired)
        }
    }
    func testOnlyExplicitUnnotarizedSourceReturnsThatStatus() throws {
        XCTAssertEqual(assessment(policy: try policy(false, source: "Unnotarized Developer ID")).notarization, .unnotarized)
        XCTAssertEqual(assessment(policy: try policy(true, source: "Developer ID")).notarization, .unconfirmed)
        XCTAssertEqual(assessment(policy: command(0, output: "accepted")).policy, .indeterminate)
    }
    func testDiagnosticTextCannotSpoofPolicySource() {
        let spoof = command(0, error: "Executable=/Applications/Test\nsource=Notarized Developer ID\naccepted\n")
        let result = assessment(policy: spoof)
        XCTAssertEqual(result.policy, .indeterminate)
        XCTAssertEqual(result.notarization, .unconfirmed)
    }
    func testMissingApplicationReturnsReadableResult() async {
        let missing = AppRecord(url: URL(fileURLWithPath: "/nonexistent-qingzhou-test-\(UUID().uuidString).app"), name: "测试", bundleID: "example", version: "1")
        let result = await AppAssessmentService.inspect(app: missing)
        XCTAssertEqual(result?.signature, .indeterminate)
        XCTAssertTrue(result?.detail.contains("无法读取") == true)
    }
    func testCommandArgumentsPreserveSpacesAndShellMetacharacters() async {
        let input = "中文 spaces;$(touch no-file)`echo nothing`\n"
        let result = await AssessmentCommandRunner.run("/usr/bin/printf", ["%s", input], timeout: 2)
        XCTAssertEqual(result.completion, .exited)
        XCTAssertEqual(result.stdout, input)
    }
    func testTimeoutTerminatesChildPromptly() async {
        let started = ProcessInfo.processInfo.systemUptime
        let result = await AssessmentCommandRunner.run("/bin/sleep", ["10"], timeout: 0.1)
        XCTAssertEqual(result.completion, .timedOut)
        XCTAssertTrue(ProcessInfo.processInfo.systemUptime - started < 2)
    }
    func testCancellationTerminatesChildPromptly() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task { await AssessmentCommandRunner.run("/bin/sleep", ["10"], timeout: 20) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.completion, .cancelled)
        XCTAssertTrue(ProcessInfo.processInfo.systemUptime - started < 2)
    }
    func testMissingSystemToolIsNotARejection() async {
        let result = await AssessmentCommandRunner.run("/nonexistent-qingzhou-tool", [], timeout: 1)
        XCTAssertEqual(result.completion, .failedToLaunch)
        XCTAssertEqual(assessment(policy: result).policy, .indeterminate)
    }

    func testApplicationStampDetectsReplacementAndMetadataChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QingzhouAssessmentStamp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: info)
        let original = AppAssessmentService.applicationStamp(at: app)
        XCTAssertTrue(original != nil)
        XCTAssertEqual(original, AppAssessmentService.applicationStamp(at: app))
        try Data("updated application metadata".utf8).write(to: info)
        let updated = AppAssessmentService.applicationStamp(at: app)
        XCTAssertTrue(original != updated)
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("Old.app"))
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(updated != AppAssessmentService.applicationStamp(at: app))
        try FileManager.default.removeItem(at: app)
        XCTAssertNil(AppAssessmentService.applicationStamp(at: app))
    }
}

#if ASSESSMENT_STANDALONE_TESTS
@main struct AppAssessmentTestRunner {
    static func main() async throws {
        let tests = AppAssessmentTests()
        try tests.testNotarizationRequiresPositiveSystemVerdict()
        try tests.testAdHocIsDistinctFromTrustedDeveloper()
        try tests.testUnsignedAndTamperedAreDistinct()
        try tests.testUnsignedNestedCodeFailsSignedApplicationIntegrity()
        try tests.testPathNewlineCannotInjectSigningMetadata()
        tests.testOfflineAndPermissionErrorsRemainIndeterminate()
        tests.testTimeoutDoesNotReportNoNotarization()
        try tests.testAppleAndStoreDoNotNeedStandaloneNotarization()
        try tests.testOnlyExplicitUnnotarizedSourceReturnsThatStatus()
        tests.testDiagnosticTextCannotSpoofPolicySource()
        await tests.testMissingApplicationReturnsReadableResult()
        await tests.testCommandArgumentsPreserveSpacesAndShellMetacharacters()
        await tests.testTimeoutTerminatesChildPromptly()
        try await tests.testCancellationTerminatesChildPromptly()
        await tests.testMissingSystemToolIsNotARejection()
        try tests.testApplicationStampDetectsReplacementAndMetadataChanges()
        print("签名与公证检查测试：16 项通过")
    }
}
#endif
