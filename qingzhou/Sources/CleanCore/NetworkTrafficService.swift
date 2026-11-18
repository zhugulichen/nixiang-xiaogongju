import Foundation
import Darwin

public struct NetworkProcessTraffic: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let received: UInt64
    public let sent: UInt64
}

public struct NetworkTrafficSample: Sendable {
    public let date: Date
    public let duration: TimeInterval
    public let processes: [NetworkProcessTraffic]
    public let skippedRows: Int
}

/// Each repeated header closes the preceding frame. The first frame contains lifetime counters,
/// so it is deliberately discarded rather than charged to the new monitoring session.
struct NetworkTrafficParser {
    private var indices: (Int, Int)?
    private var frame: [Int32: NetworkProcessTraffic] = [:]
    private var frameDate: Date?
    private var duration: TimeInterval = 2
    private var hasBaseline = false
    private var skipped = 0
    private(set) var recognizedHeader = false

    mutating func consume(_ line: String, at date: Date = Date()) -> NetworkTrafficSample? {
        guard let columns = Self.csv(line) else { skipped += 1; return nil }
        if columns.first == "", let input = columns.firstIndex(of: "bytes_in"), let output = columns.firstIndex(of: "bytes_out") {
            let result = hasBaseline && frameDate != nil
                ? NetworkTrafficSample(date: frameDate!, duration: duration, processes: Array(frame.values), skippedRows: skipped) : nil
            if let frameDate { duration = max(0.1, date.timeIntervalSince(frameDate)); hasBaseline = true }
            frameDate = date; frame = [:]; skipped = 0; indices = (input, output); recognizedHeader = true
            return result
        }
        guard !line.isEmpty else { return nil }
        guard let (input, output) = indices, columns.count > max(input, output),
              let identity = columns.first, let dot = identity.lastIndex(of: "."),
              let pid = Int32(identity[identity.index(after: dot)...]), pid > 0,
              let received = UInt64(columns[input]), let sent = UInt64(columns[output]),
              !frame.keys.contains(pid) else { skipped += 1; return nil }
        frame[pid] = NetworkProcessTraffic(pid: pid, name: String(identity[..<dot]), received: received, sent: sent)
        return nil
    }

    func finish() -> NetworkTrafficSample? {
        guard hasBaseline, let frameDate else { return nil }
        return NetworkTrafficSample(date: frameDate, duration: duration, processes: Array(frame.values), skippedRows: skipped)
    }

    static func csv(_ line: String) -> [String]? {
        var result: [String] = [], field = "", quoted = false
        let characters = Array(line.trimmingCharacters(in: .newlines))
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else if quoted || field.isEmpty { quoted.toggle() }
                else { return nil }
            } else if c == "," && !quoted { result.append(field); field = "" }
            else { field.append(c) }
            index += 1
        }
        guard !quoted else { return nil }
        result.append(field); return result
    }
}

public enum NetworkTrafficError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { switch self { case .unavailable(let message): return message } }
}

public enum NetworkTrafficService {
    public static func samples() -> AsyncThrowingStream<NetworkTrafficSample, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let sample = try await sample()
                        try Task.checkCancellation()
                        continuation.yield(sample)
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sample() async throws -> NetworkTrafficSample {
        // Finite windows avoid stdio buffering in nettop's indefinite logging mode.
        let result = await AssessmentCommandRunner.run("/usr/bin/nettop",
            ["-L", "2", "-s", "1", "-d", "-P", "-x", "-n", "-J", "bytes_in,bytes_out", "-t", "external"], timeout: 6)
        if result.completion == .cancelled { throw CancellationError() }
        guard result.succeeded else { throw NetworkTrafficError.unavailable("系统网络采样未完成，可能受到权限限制或发生超时。请重新开始监测。") }
        var parser = NetworkTrafficParser(), headers = 0
        let end = Date()
        for line in result.stdout.components(separatedBy: .newlines) {
            let isHeader = line.hasPrefix(",") && line.contains("bytes_in") && line.contains("bytes_out")
            if isHeader { headers += 1 }
            _ = parser.consume(line, at: end.addingTimeInterval(Double(headers - 2)))
        }
        guard headers == 2, result.stdout.utf8.count < 65_536, result.stdout.hasSuffix("\n"), let sample = parser.finish() else {
            throw NetworkTrafficError.unavailable("系统采样格式不完整，暂不能确定网络用量。")
        }
        return sample
    }

    /// Map only by the executable's actual path; process names alone cannot prove app ownership.
    public static func applicationURL(for pid: Int32) -> URL? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro that Swift cannot import in some SDKs.
        let size = 4 * Int(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: size)
        guard proc_pidpath(pid, &buffer, UInt32(size)) > 0 else { return nil }
        var url = URL(fileURLWithPath: String(cString: buffer)).deletingLastPathComponent()
        var result: URL?
        while url.path != "/" {
            if url.pathExtension.lowercased() == "app" { result = url }
            url.deleteLastPathComponent()
        }
        return result
    }
}

public struct NetworkUsageRow: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let appURL: URL?
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public var receiveRate: Double = 0
    public var sendRate: Double = 0
    public var activeProcesses = 0
}

public struct NetworkTrafficTotals: Sendable {
    public private(set) var rows: [String: NetworkUsageRow] = [:]
    public private(set) var observedDuration: TimeInterval = 0
    public private(set) var skippedRows = 0
    public init() {}
    public mutating func consume(_ sample: NetworkTrafficSample, appURL: (Int32) -> URL?, appNames: [String: String] = [:]) {
        for key in Array(rows.keys) { rows[key]?.receiveRate = 0; rows[key]?.sendRate = 0; rows[key]?.activeProcesses = 0 }
        observedDuration += sample.duration; skippedRows += sample.skippedRows
        for process in sample.processes {
            let url = appURL(process.pid)?.standardizedFileURL
            let id = url?.path ?? "process:\(process.pid):\(process.name)"
            var row = rows[id] ?? NetworkUsageRow(id: id, name: url.map { appNames[$0.path] ?? $0.deletingPathExtension().lastPathComponent } ?? process.name, appURL: url)
            row.received = Self.add(row.received, process.received); row.sent = Self.add(row.sent, process.sent)
            row.receiveRate += Double(process.received) / max(0.1, sample.duration)
            row.sendRate += Double(process.sent) / max(0.1, sample.duration)
            row.activeProcesses += 1; rows[id] = row
        }
    }
    private static func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let result = left.addingReportingOverflow(right); return result.overflow ? .max : result.partialValue
    }
}

