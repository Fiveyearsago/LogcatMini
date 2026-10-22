import SwiftUI
import LogcatCore

/// Each lazy row observes model updates, including when it moves between sections.
struct AppListRow: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var builds: LocalBuildController
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let available: Bool
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }

    var body: some View {
        let isFavorite = model.favorites.contains(id)
        let displayTitle = isFavorite ? (model.favoriteMetadata[id]?.label ?? title) : title
        return HStack(spacing: 5) {
            Button { model.selectPackage(id) } label: {
                HStack(spacing: 9) {
                    if isFavorite, let icon = model.favoriteIcons[id] {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: appearance.uiSize(30), height: appearance.uiSize(30)).accessibilityHidden(true)
                    } else {
                        Image(systemName: symbol).font(.system(size: appearance.uiSize(isFavorite ? 22 : 14)))
                            .foregroundColor(model.selectedPackage == id ? palette.accent : palette.muted)
                            .frame(width: isFavorite ? appearance.uiSize(30) : nil)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayTitle).font(.system(size: appearance.uiSize(12), weight: model.selectedPackage == id ? .semibold : .regular)).lineLimit(1)
                        Text(subtitle).font(.system(size: appearance.uiSize(9), design: .monospaced)).foregroundColor(palette.muted).lineLimit(1).truncationMode(.middle)
                        if !available {
                            Text("当前设备未列出").font(.system(size: appearance.uiSize(9))).foregroundColor(palette.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(Rectangle())
            }.disabled(!available).help(displayTitle + "\n" + subtitle + (available ? "" : "\n请检查设备、应用安装情况或开启「显示系统应用」"))
            if !id.isEmpty {
                Button { model.toggleFavorite(id) } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: appearance.uiSize(12)))
                        .foregroundColor(isFavorite ? palette.accent : palette.muted)
                        .frame(width: 24, height: 32).contentShape(Rectangle())
                }.help(isFavorite ? "取消收藏 " + id : "收藏 " + id)
                    .accessibilityLabel((isFavorite ? "取消收藏 " : "收藏 ") + id)
            }
            if model.selectedPackage == id { RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 3, height: 23) }
        }.buttonStyle(.plain).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 7).fill(model.selectedPackage == id ? palette.accent.opacity(0.10) : .clear))
            .padding(.horizontal, 12)
            .contextMenu {
                if !id.isEmpty {
                    Button("关联 / 配置本地项目…") { builds.edit(id); openWindow(id: "local-build") }
                    if let project = builds.project(for: id) {
                        Button("编译并运行到当前手机") {
                            if let target = model.localBuildTarget {
                                builds.edit(id)
                                if !builds.start(project, target: target) { openWindow(id: "local-build") }
                            }
                        }.disabled(builds.busy || builds.detecting || model.localBuildTarget == nil || model.mirror.installer.isInstalling)
                    }
                }
            }
    }
}
