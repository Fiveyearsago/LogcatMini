import SwiftUI
import AppKit
import LogcatCore

struct RequestReplayView: View {
    @ObservedObject var store: RequestReplayStore
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var history = false
    @State private var search = ""
    @State private var tab = "body"
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    var body: some View {
        HSplitView {
            if !store.responseFullscreen { sidebar.frame(minWidth: 230, idealWidth: 270, maxWidth: 360) }
            VStack(alignment: .leading, spacing: 12) {
                if !store.responseFullscreen { requestControls }
                Group {
                    switch tab {
                    case "headers": headersEditor
                    case "crypto": cryptoEditor
                    case "response": responseViewer
                    default: bodyEditor
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !store.responseFullscreen {
                    HStack {
                        Text(store.draft.source.isEmpty ? "手动请求" : store.draft.source).lineLimit(1)
                        Spacer()
                        Text("历史保存在本机 · 最近 200 次发送")
                    }.font(.system(size: 10)).foregroundColor(palette.muted)
                }
            }.padding(16).frame(minWidth: 680)
        }.background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
            .onChange(of: store.response) { result in if result != nil { tab = "response" } }
    }
    private var requestControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            HStack(spacing: 10) {
                Picker("方法", selection: $store.draft.method) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 100).accessibilityLabel("请求方法")
                TextField("https://example.com/api", text: $store.draft.url).accessibilityLabel("请求 URL")
                Text("超时")
                TextField("秒", value: $store.draft.timeout, formatter: NumberFormatter()).frame(width: 42).accessibilityLabel("请求超时秒数")
                Text("秒").foregroundColor(palette.muted)
            }.disabled(store.busy)
            if !store.draft.importNotes.isEmpty {
                Text("导入信息（不影响发送）：" + store.draft.importNotes)
                    .font(.system(size: 11)).foregroundColor(palette.muted).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(palette.chip).cornerRadius(6)
            }
            if let error = store.error { message(error, color: palette.error) }
            else if let notice = store.notice { message(notice, color: palette.accent) }
            Picker("编辑区域", selection: $tab) {
                Text("Request Body").tag("body")
                Text("请求头").tag("headers")
                Text("s 解密 / 加密").tag("crypto")
                Text("响应").tag("response")
            }.pickerStyle(.segmented).labelsHidden()
        }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundColor(palette.accent)
            TextField("为接口命名", text: $store.draft.name).font(.system(size: 15, weight: .semibold))
                .accessibilityLabel("接口名称").disabled(store.busy)
            Button("保存") { store.save() }.disabled(store.busy)
            Button("复制为新请求") { store.duplicate() }.disabled(store.busy)
            if store.sending {
                ProgressView().controlSize(.small)
                Button("取消请求") { store.cancel() }
            } else {
                Button { store.send() } label: { Label("发送请求", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent).disabled(!store.canSend)
                    .help("GET / HEAD 填写 URL 即可发送；其他方法填写 URL 和 Request Body。发送当前报文，响应写入历史。")
            }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模拟接口请求").font(.headline)
                Spacer()
                Button { store.newRequest(); tab = "body" } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建接口请求").disabled(store.busy)
            }
            Picker("记录类型", selection: $history) {
                Text("已保存 \(store.requests.count)").tag(false)
                Text("发送历史 \(store.records.count)").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            TextField("搜索名称或 URL", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if history {
                        ForEach(store.records.filter { matches($0.request) }) { record in
                            Button { store.restore(record); tab = "response" } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.request.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(record.request.method + " " + record.request.url).font(.system(size: 10, design: .monospaced)).lineLimit(2).foregroundColor(palette.muted)
                                    HStack {
                                        Text(record.date, format: .dateTime.month().day().hour().minute().second())
                                        Spacer()
                                        Text(record.response?.status.map { "HTTP \($0)" } ?? (record.response == nil ? "进行中" : "未完成"))
                                    }.font(.system(size: 10)).foregroundColor(palette.muted)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(palette.field).cornerRadius(6)
                            }.buttonStyle(.plain).contextMenu { Button("删除这条发送记录", role: .destructive) { store.deleteRecord(record.id) } }
                        }
                    } else {
                        ForEach(store.requests.filter(matches)) { request in
                            Button { store.load(request); tab = "body" } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(request.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(request.method + " " + request.url).font(.system(size: 10, design: .monospaced)).lineLimit(2).foregroundColor(palette.muted)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(request.id == store.draft.id ? palette.accent.opacity(0.13) : palette.field).cornerRadius(6)
                            }.buttonStyle(.plain).contextMenu { Button("删除已保存请求", role: .destructive) { store.deleteRequest(request.id) } }
                        }
                    }
                }.disabled(store.busy)
                if (history ? store.records.isEmpty : store.requests.isEmpty) {
                    Text(history ? "发送后自动记录请求、响应和耗时。" : "从日志详情导入，或点击 + 创建请求。命名后点击保存可重复使用。")
                        .font(.system(size: 12)).foregroundColor(palette.muted).padding(.top, 24)
                }
            }
            Button("在 Finder 中查看记录") { NSWorkspace.shared.activateFileViewerSelecting([store.catalogURL]) }
                .font(.system(size: 11)).buttonStyle(.borderless)
        }.padding(12).background(palette.panel)
    }
    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.usesURLS ? "GET / HEAD 仅发送 URL 和请求头，不发送 Body" : "实际发送的 Body · 支持 JSON、表单或原始文本").font(.system(size: 12)).foregroundColor(palette.muted)
                Spacer()
                Button("格式化 JSON") { formatBody() }.disabled(store.busy || store.usesURLS)
            }
            editor($store.draft.body, label: "请求 Body").disabled(store.busy || store.usesURLS)
            if store.hasUnappliedPlain { Text("明文修改尚未写回，发送时使用当前 URL / Request Body。需要发送修改后的内容时，请先写回。").font(.system(size: 11)).foregroundColor(palette.muted) }
        }
    }
    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每行 Header: value。Host、Content-Length 等传输头由客户端重新计算。")
                .font(.system(size: 12)).foregroundColor(palette.muted)
            editor($store.draft.headers, label: "请求头").disabled(store.busy)
        }
    }
    private var cryptoEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("s 位置", selection: Binding(get: { store.effectiveSLocation }, set: { store.sLocation = $0 })) {
                    ForEach(ReplaySLocation.allCases) { Text($0.title).tag($0) }
                }.frame(width: 235).disabled(store.busy || store.usesURLS)
                Picker("模式", selection: $store.decryptionMode) { Text("old").tag("old"); Text("new").tag("new") }.frame(width: 110).disabled(store.busy)
                Button("服务解密 s") { store.decryptUsingService() }.disabled(store.busy)
                if store.decrypting { ProgressView().controlSize(.small); Button("取消") { store.cancelDecryption() } }
                Spacer()
            }
            if store.usesURLS {
                Text("GET / HEAD 自动从当前 URL 提取 s 并解码；修改后写回 URL，保留其他查询参数。")
                    .font(.system(size: 11)).foregroundColor(palette.muted)
            }
            TextField("解密服务 URL（自行配置，留空时不发送）", text: $store.serviceEndpoint)
                .textFieldStyle(.roundedBorder).disabled(store.busy).accessibilityLabel("解密服务地址")
            Text("仅在点击服务解密后，将所选 s 发送到上方地址。请确认该服务可信且支持此报文格式。")
                .font(.system(size: 11)).foregroundColor(palette.muted)
            HStack {
                Button("本机解密 s") { store.decryptS() }
                Button("导入 RSA 私钥…") { store.importPrivateKey() }
                Text(store.privateKeyName.map { "私钥：\($0)（本次运行）" } ?? "本机解密 type 3 需要私钥")
                Spacer()
                if store.privateKeyName != nil { Button("移除私钥") { store.forgetPrivateKey() } }
            }.font(.system(size: 11)).foregroundColor(palette.muted).disabled(store.busy)
            HStack {
                Button("导入 RSA 公钥…") { store.importPublicKey() }
                Text(store.publicKeyName.map { "公钥：\($0)（本次运行）" } ?? "加密写回需要导入目标服务公钥")
                if store.publicKeyName != nil { Button("移除公钥") { store.forgetPublicKey() } }
            }.font(.system(size: 11)).foregroundColor(palette.muted).disabled(store.busy)
            editor($store.plain, label: "s 明文参数").disabled(store.busy)
            HStack {
                Button("加密并写回 s") { store.applyPlain(encrypt: true) }.buttonStyle(.borderedProminent)
                Button("明文写回 s") { store.applyPlain(encrypt: false) }
                Button("明文作为 JSON Body") { store.applyPlain(encrypt: false, wholeBody: true) }.disabled(store.usesURLS)
                Spacer()
                Button("清空明文") { store.discardPlain() }
            }.disabled(store.busy)
            Text(store.hasUnappliedPlain ? "明文修改尚未写回，发送时仍使用当前 URL / Request Body。" : "可解密后编辑，也可直接粘贴完整明文。写回后在 Body / URL 中核对最终报文。")
                .font(.system(size: 11)).foregroundColor(store.hasUnappliedPlain ? palette.warning : palette.muted)
        }
    }
    private var responseViewer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = store.response {
                RequestResponseView(response: result, appearance: appearance, fullscreen: store.responseFullscreen, toggleFullscreen: {
                    store.responseFullscreen.toggle()
                })
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 32)).foregroundColor(palette.muted)
                    Text(store.sending ? "正在等待响应…" : "发送请求，或选择一条发送历史查看响应。")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func editor(_ value: Binding<String>, label: String) -> some View {
        TextEditor(text: value).font(.system(size: appearance.fontSize, design: .monospaced))
            .scrollContentBackground(.hidden).padding(6).background(palette.field)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.line)).accessibilityLabel(label)
    }
    private func message(_ text: String, color: Color) -> some View { Text(text).font(.system(size: 12)).foregroundColor(color).textSelection(.enabled) }
    private func matches(_ request: ReplayRequest) -> Bool { search.isEmpty || (request.name + " " + request.url).localizedCaseInsensitiveContains(search) }
    private func pretty(_ text: String) -> String {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { return text }
        return LogFormattedDocument.parse(text)?.text ?? text
    }
    private func formatBody() {
        guard (try? JSONSerialization.jsonObject(with: Data(store.draft.body.utf8))) != nil else { store.error = "Body 不是有效的 JSON。"; return }
        store.draft.body = pretty(store.draft.body)
    }
}
