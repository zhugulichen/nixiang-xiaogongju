import SwiftUI
import CleanCore

@MainActor private final class AppAssessmentModel: ObservableObject {
    @Published var result: AppAssessment?
    @Published var working = false
    @Published var cancelled = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(_ app: AppRecord) {
        cancel(); let token = UUID(); generation = token
        working = true; cancelled = false; result = nil
        task = Task { [weak self] in
            let result = await AppAssessmentService.inspect(app: app)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.result = result; self.working = false; self.task = nil
        }
    }
    func cancel() {
        task?.cancel(); task = nil; generation = UUID()
        if working { cancelled = true }
        working = false
    }
    deinit { task?.cancel() }
}

struct AppAssessmentView: View {
    let app: AppRecord
    @Environment(\.dismiss) private var dismiss
    @StateObject private var assessment = AppAssessmentModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIcon(url: app.url, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("签名与公证检查").font(.title2.bold())
                    Text(app.name).font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("只读取应用，不修改签名或系统安全设置。系统可能联网确认公证。").font(.caption).foregroundStyle(.secondary)
            Divider()
            if assessment.working {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("正在检查签名、内嵌组件及系统启动政策…").font(.callout)
                    Spacer()
                    Button("取消检查") { assessment.cancel() }
                }.padding(.vertical, 20)
            } else if let result = assessment.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        row("签名完整性", result.signature.rawValue, symbol: "signature")
                        row("启动政策", result.policy.rawValue, symbol: "shield")
                        row("苹果公证", result.notarization.rawValue, symbol: "checkmark.seal")
                        if let signer = result.signer { row("证书签署者", signer, symbol: "person.text.rectangle") }
                        if let team = result.teamIdentifier { row("开发者团队", team, symbol: "person.2") }
                        Text(result.detail).font(.caption).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        Text("检查时间：\(result.checkedAt.formatted(date: .abbreviated, time: .standard))").font(.caption2).foregroundStyle(.tertiary)
                        DisclosureGroup("查看系统原始报告") {
                            Text(result.diagnostic.isEmpty ? "系统未返回详细报告。" : result.diagnostic)
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.caption)
                    }
                }
            } else {
                Text(assessment.cancelled ? "检查已取消。" : "尚未取得检查结果。").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text(app.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("重新检查") { assessment.start(app) }.disabled(assessment.working)
            }
        }
        .padding(26).frame(width: 650, height: 550)
        .onAppear { assessment.start(app) }
        .onChange(of: app.id) { _, _ in assessment.start(app) }
        .onDisappear { assessment.cancel() }
    }

    private func row(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 115, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
