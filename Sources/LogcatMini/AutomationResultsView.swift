import SwiftUI
import AppKit
import LogcatCore

struct AutomationResultsView: View {
    @ObservedObject var automation: AutomationModel
    let result: AutomationResult
    @State private var selectedCase: String?
    @State private var preview: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.name).font(.title2.bold())
                    Text("\(result.apk.packageName) · \(result.apk.versionName) (\(result.apk.versionCode)) · \(result.deviceName)").font(.caption).textSelection(.enabled)
                }
                Spacer()
                if automation.busy { Button("停止测试", role: .destructive, action: automation.stop) }
                else {
                    Button("复测失败 / 阻塞") { automation.rerunFailures(result) }.disabled(result.count(.failed) + result.count(.blocked) == 0)
                    Button("导出 MD 报告…") { automation.exportResult(result) }
                }
            }
            HStack(spacing: 18) {
                if automation.busy { ProgressView().controlSize(.small) }
                Text(result.verdict).font(.headline)
                Spacer()
                ForEach([TestStatus.passed, .failed, .blocked, .cancelled, .notRun], id: \.self) { status in
                    HStack(spacing: 4) { StatusPill(status: status); Text("\(result.count(status))").monospacedDigit() }
                }
            }
            Text(result.reason.isEmpty ? result.phase : result.reason).font(.callout).foregroundColor(.secondary).textSelection(.enabled)
            Divider()
            HSplitView {
                List(selection: $selectedCase) {
                    ForEach(result.cases) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name).font(.headline)
                            HStack { StatusPill(status: item.status); Text(item.id).font(.caption) }
                        }.padding(.vertical, 6).tag(item.id)
                    }
                }.frame(minWidth: 210, idealWidth: 265, maxWidth: 350)
                ScrollView {
                    if let item = result.cases.first(where: { $0.id == selectedCase }) ?? result.cases.first {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(item.name).font(.title3.bold())
                            Text("验收目标：\(item.requirement)").textSelection(.enabled)
                            if !item.reason.isEmpty { Text(item.reason).foregroundColor(item.status == .failed ? .red : .orange).textSelection(.enabled) }
                            ForEach(item.steps) { step in
                                GroupBox {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(step.name).font(.headline); Spacer(); StatusPill(status: step.status)
                                            Text(String(format: "%.1f s", step.duration)).font(.caption).monospacedDigit()
                                        }
                                        Text("\(step.phase) · \(step.action)").font(.caption).foregroundColor(.secondary)
                                        Text("预期：\(step.expected)").textSelection(.enabled)
                                        if !step.actual.isEmpty { Text("实际：\(step.actual)").textSelection(.enabled) }
                                        HStack {
                                            if let screenshot = step.screenshot { Button("查看截图") {
                                                if let dir = automation.directory(for: result), AutomationReport.artifactExists(screenshot, in: dir) { preview = dir.appendingPathComponent(screenshot) }
                                                else { automation.error = "截图文件缺失" }
                                            } }
                                            if let log = step.log { Button("打开步骤日志") { automation.openArtifact(log, for: result) } }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }
                            }
                            if !result.warnings.isEmpty { Text(result.warnings.joined(separator: "\n")).font(.caption).foregroundColor(.secondary) }
                            Text("结果只覆盖所选用例及本次设备、APK 和环境。").font(.caption).foregroundColor(.secondary)
                        }.padding(14)
                    }
                }.frame(minWidth: 440, maxWidth: .infinity)
            }
            HStack {
                Text("运行编号：\(result.id)").font(.caption).textSelection(.enabled)
                Spacer()
                Button("打开 MD") { automation.openArtifact("report.md", for: result) }
                Button("结果目录") { if let dir = automation.directory(for: result) { NSWorkspace.shared.activateFileViewerSelecting([dir]) } }
            }
        }.padding(22)
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack {
                if let preview, let image = NSImage(contentsOf: preview) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Text("无法读取截图") }
                Button("关闭") { preview = nil }.keyboardShortcut(.cancelAction)
            }.padding(16).frame(width: 600, height: 720)
        }
    }
}
