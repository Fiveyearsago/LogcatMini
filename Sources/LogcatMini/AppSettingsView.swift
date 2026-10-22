import SwiftUI
import LogcatCore

struct AppSettingsView: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var library: MediaLibrary
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("设置").font(.title2.bold())
                    Text("调整阅读体验和文件保存位置").foregroundColor(palette.muted)
                }
                settingsCard("本地项目", symbol: "hammer") {
                    Text("关联 Android 源码目录，编译、安装并运行到当前手机。配置仅保存在这台 Mac 上。")
                        .font(.caption).foregroundColor(palette.muted)
                    Button("管理项目与构建输出…") { openWindow(id: "local-build") }
                }
                settingsCard("截图与录屏", symbol: "folder") {
                    ForEach(CaptureKind.allCases) { kind in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: kind.symbol).frame(width: 20).foregroundColor(palette.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(kind.title)保存文件夹").font(.headline)
                                Text(library.directory(for: kind)?.path ?? "尚未选择，首次保存时设置")
                                    .font(.system(size: 12)).foregroundColor(palette.muted)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button("更换…") { library.chooseDirectory(for: kind) }
                                .accessibilityLabel("更换\(kind.title)文件夹")
                        }
                        if kind == .screenshot { Divider().padding(.vertical, 4) }
                    }
                    Text("自动命名并保存，无需重复选择。更换文件夹后，历史记录和原文件仍会保留。")
                        .font(.caption).foregroundColor(palette.muted).padding(.top, 6)
                }
                settingsCard("外观与文字", symbol: "paintpalette") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 10) {
                        ForEach(AppTheme.allCases) { theme in
                            let colors = theme.palette(for: colorScheme)
                            Button { appearance.theme = theme } label: {
                                HStack(spacing: 7) {
                                    Circle().fill(colors.canvas).overlay(Circle().stroke(colors.accent, lineWidth: 2)).frame(width: 16, height: 16)
                                    Text(theme.title)
                                    Spacer(minLength: 0)
                                    if appearance.theme == theme { Image(systemName: "checkmark").font(.caption.bold()) }
                                }.padding(10).foregroundColor(appearance.theme == theme ? palette.accent : palette.text)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(appearance.theme == theme ? palette.accent.opacity(0.14) : palette.field))
                            }.buttonStyle(.plain).accessibilityLabel("主题：\(theme.title)")
                        }
                    }
                    Divider().padding(.vertical, 7)
                    HStack {
                        Text("日志字号")
                        Spacer()
                        Stepper("\(Int(appearance.fontSize)) pt", value: Binding(get: { appearance.fontSize }, set: appearance.setFontSize), in: AppearanceSettings.fontRange, step: 1)
                            .fixedSize().accessibilityLabel("日志字号")
                        Button("恢复默认", action: appearance.resetFontSize)
                    }
                    Text("保留快捷键：⌘+ 放大、⌘− 缩小、⌘0 恢复默认")
                        .font(.caption).foregroundColor(palette.muted)
                    Text("D  12:30:45.123  日志预览 key=value")
                        .font(.system(size: appearance.fontSize, design: .monospaced))
                        .foregroundColor(palette.accent).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(palette.field).cornerRadius(6)
                }
                settingsCard("日志与设备", symbol: "slider.horizontal.3") {
                    Toggle("详情日志默认格式化", isOn: $appearance.formatDetailByDefault)
                    Text("打开日志详情时自动格式化。关闭后默认显示原始日志，仍可用“格式化日志”或 ⌘J 切换。")
                        .font(.caption).foregroundColor(palette.muted)
                    Divider().padding(.vertical, 7)
                    Text("日志列表显示列").font(.headline)
                    HStack(spacing: 16) {
                        ForEach(LogColumn.allCases) { column in
                            Toggle(column.title, isOn: Binding(get: { appearance.columns.contains(column) }, set: { appearance.setColumn(column, visible: $0) }))
                                .toggleStyle(.checkbox).disabled(!appearance.columns.canToggle(column))
                        }
                    }
                    Button("恢复默认显示列", action: appearance.resetColumns).padding(.bottom, 7)
                    Toggle("应用列表显示系统应用", isOn: $model.includeSystem)
                        .onChange(of: model.includeSystem) { _ in Task { await model.refreshPackages() } }
                    Divider().padding(.vertical, 7)
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ADB").font(.headline)
                            Text(model.adbPath ?? "尚未配置")
                                .font(.caption).foregroundColor(palette.muted).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("更换 ADB…", action: model.chooseADB)
                    }
                }
                if let error = library.error {
                    HStack { Text(error).foregroundColor(palette.error); Spacer(); Button("关闭") { library.error = nil } }
                }
            }.padding(26)
        }.background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
    }
    private func settingsCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline).foregroundColor(palette.accent)
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(palette.panel))
    }
}
