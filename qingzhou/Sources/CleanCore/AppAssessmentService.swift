import Foundation
import Darwin

public enum AppSignatureStatus: String, Sendable {
    case valid = "签名完整性通过"
    case adHoc = "临时签名，完整性通过"
    case unsigned = "未签名"
    case invalid = "签名完整性未通过"
    case indeterminate = "未能完成签名检查"
}

public enum AppPolicyStatus: String, Sendable {
    case accepted = "系统启动评估通过"
    case rejected = "系统启动评估未通过"
    case indeterminate = "系统启动评估未确定"
}

public enum AppNotarizationStatus: String, Sendable {
    case confirmed = "已确认苹果公证"
    case unnotarized = "系统未认可苹果公证"
    case notRequired = "苹果系统或商店应用，无需单独公证"
    case unconfirmed = "尚未确认苹果公证"
}

public struct AppAssessment: Sendable {
    public let applicationURL: URL
    public let checkedAt: Date
    public let signature: AppSignatureStatus
    public let policy: AppPolicyStatus
    public let notarization: AppNotarizationStatus
    public let signer: String?
    public let teamIdentifier: String?
    public let detail: String
    public let diagnostic: String
}

public enum AppAssessmentService {
    /// Only the system's inspection tools are executed; the selected application is never launched.
    /// Cancellation returns nil so callers cannot publish a partial result for a different selection.
    public static func inspect(app: AppRecord) async -> AppAssessment? {
        let url = app.url.standardizedFileURL
        guard !Task.isCancelled else { return nil }
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
            return AppAssessment(applicationURL: url, checkedAt: Date(), signature: .indeterminate,
                                 policy: .indeterminate, notarization: .unconfirmed, signer: nil,
                                 teamIdentifier: nil, detail: "应用已移动、无法读取，或不是有效的应用文件夹。", diagnostic: "")
        }
        let initialStamp = applicationStamp(at: url)
        async let display = AssessmentCommandRunner.run("/usr/bin/codesign", ["--display", "--verbose=4", url.path], timeout: 8)
        async let verification = AssessmentCommandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", url.path], timeout: 25)
        async let policy = AssessmentCommandRunner.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--raw", "--ignore-cache", "--no-cache", url.path], timeout: 25)
        let results = await (display, verification, policy)
        guard !Task.isCancelled, ![results.0, results.1, results.2].contains(where: { $0.completion == .cancelled }) else { return nil }
        guard initialStamp != nil, initialStamp == applicationStamp(at: url) else {
            return AppAssessment(applicationURL: url, checkedAt: Date(), signature: .indeterminate,
                                 policy: .indeterminate, notarization: .unconfirmed, signer: nil,
                                 teamIdentifier: nil, detail: "检查期间应用已更新、替换或无法读取，请重新检查。", diagnostic: "")
        }
        return interpret(url: url, display: results.0, verification: results.1, policyResult: results.2)
    }

    // Do not combine results from different installations while an updater replaces the bundle.
    static func applicationStamp(at url: URL) -> [String]? {
        let resolved = url.resolvingSymlinksInPath()
        let paths = [resolved, resolved.appendingPathComponent("Contents/Info.plist"),
                     resolved.appendingPathComponent("Contents/_CodeSignature/CodeResources"),
                     resolved.appendingPathComponent("Info.plist")]
        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        var result = [resolved.path]
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) else {
                if path == resolved { return nil }
                result.append("missing"); continue
            }
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber else { return nil }
            result.append("\(device.uint64Value):\(inode.uint64Value):\(modified.timeIntervalSinceReferenceDate):\(size.uint64Value)")
        }
        return result
    }

    static func interpret(url: URL, display: AssessmentCommandResult, verification: AssessmentCommandResult,
                          policyResult: AssessmentCommandResult) -> AppAssessment {
        // Strip executable paths before parsing metadata so a filename containing newlines cannot inject fields.
        let metadata = display.stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let safeMetadata = metadata.dropFirst(metadata.lastIndex { $0.hasPrefix("Identifier=") } ?? metadata.count)
        func field(_ prefix: String) -> String? {
            safeMetadata.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        let signer = display.succeeded ? field("Authority=") : nil
        let team = display.succeeded ? field("TeamIdentifier=").flatMap { $0 == "not set" ? nil : $0 } : nil
        let verificationText = verification.stderr.replacingOccurrences(of: url.path, with: "[应用]").lowercased()
        let displayText = display.stderr.replacingOccurrences(of: url.path, with: "[应用]").lowercased()
        let isUnsigned = display.completion == .exited && display.exitCode != 0 && displayText.contains(": code object is not signed at all")
        let hasUnsignedComponent = display.succeeded && verificationText.contains(": code object is not signed at all")
        let knownInvalid = ["a sealed resource is missing or invalid", "invalid signature", "code or signature modified",
                            "resource fork, finder information, or similar detritus not allowed", "unsealed contents present",
                            "the sealed resource directory is invalid", "main executable failed strict validation",
                            "code has no resources but signature indicates they must be present"].contains { verificationText.contains($0) }
        let signature: AppSignatureStatus
        if verification.succeeded {
            signature = display.succeeded && field("Signature=") == "adhoc" ? .adHoc : .valid
        } else if isUnsigned { signature = .unsigned }
        else if verification.completion == .exited && (knownInvalid || hasUnsignedComponent) { signature = .invalid }
        else { signature = .indeterminate }

        // The raw property list is separate from diagnostic stderr, avoiding localized text and path parsing.
        let raw = policyResult.stdout.data(using: .utf8).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any]
        }
        let authority = raw?["assessment:authority"] as? [String: Any]
        let source = authority?["assessment:authority:source"] as? String
        let verdict = raw?["assessment:verdict"] as? Bool
        let policy: AppPolicyStatus
        if policyResult.completion == .exited, policyResult.exitCode == 0, verdict == true { policy = .accepted }
        else if policyResult.completion == .exited, policyResult.exitCode == 3, verdict == false { policy = .rejected }
        else { policy = .indeterminate }
        let notarization: AppNotarizationStatus
        if policy == .accepted && source == "Notarized Developer ID" { notarization = .confirmed }
        else if policy != .indeterminate && source == "Unnotarized Developer ID" { notarization = .unnotarized }
        else if policy == .accepted && ["Apple System", "Mac App Store", "Apple App Store"].contains(source ?? "") { notarization = .notRequired }
        else { notarization = .unconfirmed }

        var details = ["签名完整性、系统启动政策和苹果公证是不同的检查。评估未通过不等于恶意软件；通过也不能保证绝对安全。"]
        if signature == .adHoc { details.append("临时签名用于本机构建，没有可验证的开发者证书。清舟本机版本采用这种签名。") }
        if notarization == .unnotarized { details.append("系统当前未认可此副本的公证，可能是未公证、票据不可用或已失效；请向原开发者核实。") }
        if [display, verification, policyResult].contains(where: { $0.completion == .timedOut }) { details.append("有检查已超时；相关状态保留为未确定，可稍后重试。") }
        if [display, verification, policyResult].contains(where: { $0.completion == .failedToLaunch }) { details.append("有系统检查工具无法启动，未完成的检查不能作为结论。") }
        if policy == .indeterminate { details.append("系统未返回可确认的政策结果；可能与网络、权限或系统状态有关。") }
        return AppAssessment(applicationURL: url, checkedAt: Date(), signature: signature, policy: policy,
                             notarization: notarization, signer: signer, teamIdentifier: team,
                             detail: details.joined(separator: "\n"), diagnostic: [
                                diagnostic("签名资料", display), diagnostic("完整性检查", verification), diagnostic("系统政策", policyResult)
                             ].joined(separator: "\n\n"))
    }

    private static func diagnostic(_ title: String, _ result: AssessmentCommandResult) -> String {
        let state: String
        switch result.completion {
        case .exited: state = "结束状态 \(result.exitCode ?? -1)"
        case .timedOut: state = "超时"
        case .cancelled: state = "已取消"
        case .failedToLaunch: state = "未能启动"
        }
        return "\(title)（\(state)）\n\(result.stdout)\(result.stderr)"
    }
}

enum AssessmentCommandCompletion: Sendable { case exited, timedOut, cancelled, failedToLaunch }

struct AssessmentCommandResult: Sendable {
    let completion: AssessmentCommandCompletion
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    var succeeded: Bool { completion == .exited && exitCode == 0 }
}

private final class AssessmentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum AssessmentCommandRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> AssessmentCommandResult {
        let cancellation = AssessmentCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: execute(executable, arguments, timeout: timeout, cancellation: cancellation))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                                cancellation: AssessmentCancellation) -> AssessmentCommandResult {
        if cancellation.isCancelled { return .init(completion: .cancelled, exitCode: nil, stdout: "", stderr: "") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingzhou-assessment-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputURL = directory.appendingPathComponent("output"), errorURL = directory.appendingPathComponent("error")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? error.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = output; process.standardError = error; process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"; environment["LANG"] = "C"
            process.environment = environment
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
            var completion: AssessmentCommandCompletion = .exited
            while process.isRunning {
                if cancellation.isCancelled { completion = .cancelled; break }
                if ProcessInfo.processInfo.systemUptime >= deadline { completion = .timedOut; break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            if completion != .exited && process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                let killDeadline = ProcessInfo.processInfo.systemUptime + 0.3
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            }
            func read(_ url: URL) -> String {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 65_536)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
            return .init(completion: completion, exitCode: process.isRunning ? nil : process.terminationStatus,
                         stdout: read(outputURL), stderr: read(errorURL))
        } catch {
            return .init(completion: .failedToLaunch, exitCode: nil, stdout: "", stderr: error.localizedDescription)
        }
    }
}
