import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum BastionSheet: Identifiable {
    case app(BastionApp, focusAddress: Bool = false), account
    var id: String {
        switch self {
        case .app(let app, _): return app.id.uuidString
        case .account: return "account"
        }
    }
}

struct BastionView: View {
    @ObservedObject var manager: BastionManager
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    @Binding var sheet: BastionSheet?
    @State private var deleting: BastionApp?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { sheet = .account } label: { Label("平台账号", systemImage: "person.crop.circle") }
                    .disabled(manager.actionInProgress)
                Text(manager.userName ?? (manager.accountUnreadable ? "请重新配置账号" : "未配置账号"))
                    .foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { Task { await manager.refreshAll() } } label: { Label("刷新状态", systemImage: "arrow.clockwise") }
                    .disabled(manager.userName == nil || manager.apps.isEmpty || !manager.busy.isEmpty)
                Button { sheet = .app(BastionApp()) } label: { Label("添加应用", systemImage: "plus") }
                    .buttonStyle(BastionButtonStyle(palette: palette, prominent: true)).disabled(manager.catalogUnreadable)
            }.padding(16).background(palette.panel)
            Divider().overlay(palette.line)
            if manager.apps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 32)).foregroundStyle(palette.muted)
                    Text(manager.catalogUnreadable ? "无法读取应用列表" : "还没有添加应用").font(.headline)
                    if !manager.catalogUnreadable { Text("点击「添加应用」填写应用信息和跳板机 IP。").foregroundStyle(palette.muted) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.apps) { app in
                    HStack(spacing: 12) {
                        BastionIcon(data: app.icon, size: 38, palette: palette)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.system(size: appearance.uiSize(14), weight: .semibold)).lineLimit(1)
                            Text(app.packageName).font(.system(size: appearance.uiSize(11))).foregroundStyle(palette.muted).lineLimit(1)
                        }.frame(minWidth: 95, maxWidth: .infinity, alignment: .leading)
                        Text(app.ip).font(.system(size: appearance.uiSize(12), design: .monospaced))
                            .lineLimit(2).textSelection(.enabled).frame(width: 148, alignment: .leading)
                        stateView(app).frame(width: 138, alignment: .leading)
                        actionView(app).frame(width: 95, alignment: .trailing)
                        Menu {
                            Button("编辑应用…") { sheet = .app(app) }
                            Button("移除应用…", role: .destructive) { deleting = app }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("管理 " + app.name)
                            .disabled(manager.busy[app.ip].map { $0 != .refresh } ?? false)
                    }.padding(.vertical, 7)
                        .listRowBackground(palette.canvas)
                        .listRowSeparatorTint(palette.line)
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .background(palette.canvas)
        .foregroundColor(palette.text).tint(palette.accent)
        .font(.system(size: appearance.uiSize(13)))
        .buttonStyle(BastionButtonStyle(palette: palette))
        .sheet(item: $sheet) { item in
            Group {
                switch item {
                case .app(let app, let focusAddress): BastionAppEditor(manager: manager, app: app, palette: palette, focusAddress: focusAddress)
                case .account: BastionAccountEditor(manager: manager, palette: palette)
                }
            }
            .background(palette.panel).foregroundColor(palette.text).tint(palette.accent)
            .font(.system(size: appearance.uiSize(13)))
            .buttonStyle(BastionButtonStyle(palette: palette))
        }
        .alert("移除应用？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { app in
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                do { try manager.removeApp(app) } catch { manager.error = error.localizedDescription }
            }
        } message: { app in Text("从本机应用列表移除「\(app.name)」。") }
        .alert("跳板机管理", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
            Button("好") { manager.error = nil }
        } message: { Text(manager.error ?? "") }
        .task { await manager.refreshAll() }
        .task(id: manager.transitioning) {
            let targets = manager.transitioning
            guard !targets.isEmpty else { return }
            // Follow a transition for two minutes while this tab is visible. A refresh is always available afterward.
            for _ in 0..<24 {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                for ip in targets {
                    guard !Task.isCancelled else { return }
                    if let app = manager.apps.first(where: { $0.ip == ip }) { await manager.perform(.refresh, for: app) }
                }
            }
        }
    }

    @ViewBuilder private func stateView(_ app: BastionApp) -> some View {
        let status = manager.statuses[app.ip]
        if let busy = manager.busy[app.ip] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busy == .start ? "正在开机…" : busy == .connect ? "正在打开…" : "查询中…")
            }.foregroundStyle(palette.muted)
        } else if let status {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(statusColor(status)).frame(width: 7, height: 7)
                Text(status.label).font(.callout).lineLimit(3).help(status.label)
            }
        } else {
            Text(manager.userName == nil ? "需要平台账号" : "尚未查询").foregroundStyle(palette.muted)
        }
    }

    private func statusColor(_ status: BastionManager.Status) -> Color {
        switch status {
        case .power(.running): return Color(nsColor: palette.levelColor(.debug))
        case .pending, .power(.starting), .power(.stopping): return palette.warning
        case .failed, .power(.error), .power(.missing), .power(.deleted): return palette.error
        case .power(.stopped), .power(.unknown): return palette.muted
        }
    }

    @ViewBuilder private func actionView(_ app: BastionApp) -> some View {
        switch manager.statuses[app.ip] {
        case .power(.running):
            Button("打开跳板机") { Task { await manager.perform(.connect, for: app) } }
                .disabled(manager.busy[app.ip] != nil || manager.openingDesktop || manager.savingAccount)
        case .power(.stopped):
            Button("开机") { Task { await manager.perform(.start, for: app) } }
                .disabled(manager.busy[app.ip] != nil || manager.savingAccount)
        case .failed:
            Button("重新查询") { Task { await manager.perform(.refresh, for: app) } }
                .disabled(manager.busy[app.ip] != nil || manager.savingAccount)
        default: Spacer().frame(width: 1)
        }
    }
}

private struct BastionIcon: View {
    let data: Data?
    let size: CGFloat
    let palette: ThemePalette
    var body: some View {
        Group {
            if let data, let icon = NSImage(data: data) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit()
                    .foregroundStyle(palette.muted).padding(size * 0.17)
                    .background(palette.chip, in: RoundedRectangle(cornerRadius: 7))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct BastionAppEditor: View {
    @ObservedObject var manager: BastionManager
    @State private var draft: BastionApp
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    let palette: ThemePalette

    @FocusState private var addressFocused: Bool
    let focusAddress: Bool

    init(manager: BastionManager, app: BastionApp, palette: ThemePalette, focusAddress: Bool) {
        self.focusAddress = focusAddress
        self.manager = manager; self.palette = palette; _draft = State(initialValue: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(manager.apps.contains { $0.id == draft.id } ? "编辑应用" : "添加应用").font(.title2.bold())
            HStack(spacing: 12) {
                BastionIcon(data: draft.icon, size: 48, palette: palette)
                Button("选择图标…", action: chooseIcon)
                if draft.icon != nil { Button("移除图标") { draft.icon = nil } }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { Text("应用名"); TextField("应用名", text: $draft.name).bastionField(palette).labelsHidden().accessibilityLabel("应用名") }
                GridRow { Text("包名"); TextField("com.example.app", text: $draft.packageName).bastionField(palette).labelsHidden().accessibilityLabel("包名") }
                GridRow { Text("跳板机地址"); TextField("IPv4 或 IPv6", text: $draft.ip).focused($addressFocused).bastionField(palette).labelsHidden().accessibilityLabel("跳板机地址") }
            }
            if let error { Text(error).foregroundStyle(palette.error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try manager.saveApp(draft)
                        let saved = manager.apps.first { $0.id == draft.id }
                        dismiss()
                        if let saved { Task { await manager.perform(.refresh, for: saved) } }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .buttonStyle(BastionButtonStyle(palette: palette, prominent: true))
            }
        }.padding(24).frame(width: 450)
            .onAppear { if focusAddress { addressFocused = true } }
    }
    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { error = "无法读取该图标，请选择其他图片。"; return }
        draft.icon = png; error = nil
    }
}

private struct BastionAccountEditor: View {
    @ObservedObject var manager: BastionManager
    @State private var platformURL: String
    @State private var userName: String
    @State private var password = ""
    @State private var error: String?
    @State private var confirmingRemoval = false
    @Environment(\.dismiss) private var dismiss

    let palette: ThemePalette

    init(manager: BastionManager, palette: ThemePalette) {
        self.manager = manager; self.palette = palette; _userName = State(initialValue: manager.userName ?? "")
        _platformURL = State(initialValue: manager.platformURL)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("跳板机管理平台账号").font(.title2.bold())
            Text("用于向配置的管理平台查询状态和开机。账号密码加密保存在此 Mac。")
                .foregroundStyle(palette.muted)
            TextField("平台 HTTPS 服务地址", text: $platformURL).bastionField(palette)
            TextField("平台账号", text: $userName).bastionField(palette)
            SecureField("平台密码", text: $password).bastionField(palette)
            if let error { Text(error).foregroundStyle(palette.error) }
            HStack {
                if manager.userName != nil || manager.accountUnreadable {
                    Button("移除账号", role: .destructive) { confirmingRemoval = true }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(manager.savingAccount ? "验证中…" : "验证并保存") {
                    Task {
                        do {
                            try await manager.saveAccount(userName: userName, password: password, platformURL: platformURL)
                            password = ""; dismiss()
                            await manager.refreshAll()
                        } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
                    .buttonStyle(BastionButtonStyle(palette: palette, prominent: true))
                    .disabled(platformURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }.padding(24).frame(width: 440).disabled(manager.savingAccount).interactiveDismissDisabled(manager.savingAccount)
            .alert("移除此 Mac 保存的平台账号？", isPresented: $confirmingRemoval) {
                Button("取消", role: .cancel) {}
                Button("移除", role: .destructive) {
                    do { try manager.removeAccount(); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
    }
}


private struct BastionButtonStyle: ButtonStyle {
    let palette: ThemePalette
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? palette.error : (prominent ? palette.onAccent : palette.text))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(prominent ? palette.accent : palette.chip, in: shape)
            .overlay { shape.strokeBorder(prominent ? Color.clear : palette.line) }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
    }
}

private extension View {
    func bastionField(_ palette: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(palette.field, in: shape)
            .overlay { shape.strokeBorder(palette.line).allowsHitTesting(false) }
    }
}
