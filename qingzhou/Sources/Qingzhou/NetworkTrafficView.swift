import SwiftUI
import CleanCore

@MainActor private final class NetworkTrafficModel: ObservableObject {
    @Published var rows: [NetworkUsageRow] = []
    @Published var running = false
    @Published var status = "尚未开始监测"
    @Published var observedDuration: TimeInterval = 0
    @Published var skippedRows = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func start(apps: [AppRecord]) {
        stop(); running = true; rows = []; observedDuration = 0; skippedRows = 0
        status = "正在建立基线，约 1 秒后显示首个采样…"
        let token = UUID(); generation = token
        let names = Dictionary(apps.map { ($0.url.standardizedFileURL.path, $0.name) }, uniquingKeysWith: { first, _ in first })
        task = Task { [weak self] in
            var totals = NetworkTrafficTotals()
            do {
                for try await sample in NetworkTrafficService.samples() {
                    try Task.checkCancellation()
                    let previous = totals
                    totals = await Task.detached(priority: .utility) {
                        var result = previous
                        result.consume(sample, appURL: NetworkTrafficService.applicationURL, appNames: names)
                        return result
                    }.value
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    self.rows = Array(totals.rows.values); self.observedDuration = totals.observedDuration
                    self.skippedRows = totals.skippedRows
                    self.status = "正在监测 · 最近采样 \(sample.date.formatted(date: .omitted, time: .standard))"
                }
                guard let self, self.generation == token else { return }
                self.running = false; self.zeroRates(); self.status = "采样已结束，请重新开始监测。"
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.running = false; self.zeroRates(); self.status = error.localizedDescription
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil; generation = UUID(); running = false
        zeroRates()
        status = rows.isEmpty ? "已停止监测，尚未收到完整采样。" : "已停止监测；下方保留本轮观察结果。"
    }
    private func zeroRates() { rows = rows.map { row in var value = row; value.receiveRate = 0; value.sendRate = 0; value.activeProcesses = 0; return value } }
    deinit { task?.cancel() }
}

struct NetworkTrafficView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var traffic = NetworkTrafficModel()
    @ViewState private var search = ""
    private var rows: [NetworkUsageRow] {
        traffic.rows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { Double($0.received) + Double($0.sent) > Double($1.received) + Double($1.sent) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(traffic.status).font(.headline)
                    Text("约每秒采样 · 累计已观察 \(Int(traffic.observedDuration)) 秒").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(traffic.running ? "停止监测" : "开始新一轮监测") {
                    if traffic.running { traffic.stop() } else { traffic.start(apps: model.apps) }
                }.buttonStyle(.borderedProminent)
            }.padding(24)
            Notice(text: "统计系统可见进程的网络收发，不含本机回环。根据可执行文件路径合并应用及其辅助进程，无法确认归属时单独显示进程。累计只覆盖本轮实际采样；短时连接、系统代发和权限限制可能造成遗漏。当前仅查看，不提供联网阻断。", symbol: "network")
            HStack {
                TextField("搜索应用或进程", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Spacer()
                Text("\(rows.count) 个应用或进程").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            if traffic.skippedRows > 0 { Text("有 \(traffic.skippedRows) 行系统数据无法解析，结果为部分统计。").font(.caption).foregroundStyle(.orange).padding(.horizontal, 24) }
            Divider()
            if rows.isEmpty {
                EmptyViewCard(symbol: "network", title: traffic.running ? "正在等待网络采样" : "查看应用如何使用网络", subtitle: "主动开始监测后，显示每个应用的下载、上传速率和本轮观察累计。数据仅保留在清舟内存中。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                if let url = row.appURL { AppIcon(url: url) }
                                else { Image(systemName: "gearshape.2").foregroundStyle(.secondary).frame(width: 36) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.name).font(.system(size: 13, weight: .medium))
                                    Text(row.appURL?.path ?? "进程归属未确定").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    Text("当前可见 \(row.activeProcesses) 个进程").font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text("↓ \(rate(row.receiveRate))   ↑ \(rate(row.sendRate))").font(.caption.monospacedDigit())
                                    Text("本轮观察：下载 \(bytes(row.received)) · 上传 \(bytes(row.sent))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal, 24).padding(.vertical, 14)
                            Divider().padding(.leading, 72)
                        }
                    }
                }
            }
        }.onDisappear { traffic.stop() }
    }
    private func bytes(_ value: UInt64) -> String { DisplayFormat.bytes(Int64(clamping: value)) }
    private func rate(_ value: Double) -> String { DisplayFormat.bytes(Int64(min(max(value, 0), Double(Int64.max - 1_024)))) + "/秒" }
}
