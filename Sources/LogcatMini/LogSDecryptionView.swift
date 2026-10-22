import SwiftUI
import AppKit

struct LogSDecryptionView: View {
    @ObservedObject var store: LogSDecryptionStore
    @ObservedObject var appearance: AppearanceSettings
    @StateObject private var find = LogFindState()
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("s 串解密", systemImage: "lock.open").font(.title3.bold())
                Spacer()
                Button("清空") { store.clear() }
            }
            Text(store.source.isEmpty ? "粘贴 s 串或包含 s 字段的日志，无需填写 URL 或请求方法。" : "来自日志：" + store.source)
                .font(.system(size: 12)).foregroundColor(palette.muted).lineLimit(2)
            TextEditor(text: $store.input).font(.system(size: appearance.fontSize, design: .monospaced))
                .scrollContentBackground(.hidden).padding(6).background(palette.field)
                .frame(minHeight: 90, idealHeight: 130, maxHeight: 180).accessibilityLabel("待解密的 s 串或日志")
                .disabled(store.busy)
            HStack {
                Button("从日志提取 s") { store.extract() }.disabled(store.busy)
                if store.candidates.count > 1 {
                    Menu("选择 s（\(store.candidates.count) 项）") {
                        ForEach(store.candidates.indices, id: \.self) { index in
                            Button("\(index + 1) · \(store.candidates[index].prefix(24))…（\(store.candidates[index].count) 字符）") { store.selectCandidate(index) }
                        }
                    }.disabled(store.busy)
                }
                Spacer()
                Picker("模式", selection: $store.mode) { Text("old").tag("old"); Text("new").tag("new") }.frame(width: 115).disabled(store.busy)
                if store.busy { ProgressView().controlSize(.small); Button("取消") { store.cancel() } }
                else { Button("服务解密 s") { store.decryptUsingService() }.buttonStyle(.borderedProminent).disabled(store.input.isEmpty) }
            }
            TextField("解密服务 URL（自行配置，留空时不发送）", text: $store.serviceEndpoint)
                .textFieldStyle(.roundedBorder).disabled(store.busy).accessibilityLabel("解密服务地址")
            Text("仅在点击服务解密后，将所选 s 发送到上方地址。请确认该服务可信且支持此报文格式。")
                .font(.system(size: 11)).foregroundColor(palette.muted)
            HStack {
                Button("本机解密 s") { store.decryptLocally() }.disabled(store.input.isEmpty)
                Button("导入 RSA 私钥…") { store.importPrivateKey() }
                Text(store.privateKeyName.map { "私钥：\($0)（本次运行）" } ?? "本机解密 type 3 需要私钥")
                if store.privateKeyName != nil { Button("移除私钥") { store.forgetPrivateKey() } }
            }.font(.system(size: 11)).foregroundColor(palette.muted).disabled(store.busy)
            if let error = store.error { Text(error).foregroundColor(palette.warning).textSelection(.enabled) }
            else if let notice = store.notice { Text(notice).foregroundColor(palette.accent) }
            HStack {
                Text("解密结果").font(.headline)
                Spacer()
                Button("复制明文") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.plain, forType: .string) }.disabled(store.plain.isEmpty)
            }
            DetailTextView(text: store.plain, palette: palette, fontSize: appearance.fontSize, find: find, activate: {}, accessibilityLabel: "s 解密结果")
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.field)
        }.padding(18).background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
            .onDisappear { store.cancel() }
    }
}
