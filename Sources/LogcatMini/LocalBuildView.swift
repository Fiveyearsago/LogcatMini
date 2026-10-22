import SwiftUI

struct LocalBuildView: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var builds: LocalBuildController
    @ObservedObject var appearance: AppearanceSettings
    @StateObject private var find = LogFindState()
    @State private var advanced = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    private var palette: ThemePalette { appearance.theme.palette(for: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("本地项目 · 编译并运行", systemImage: "hammer").font(.title3.bold())
                Spacer()
                Menu("已关联项目（\(builds.projects.count)）") {
                    ForEach(builds.projects) { project in Button(project.packageID) { builds.edit(project.packageID) } }
                    Divider()
                    Button("关联其他 App") { builds.edit("") }
                }.disabled(builds.busy || builds.detecting)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    pathRow("项目目录", path: $builds.draft.directory, field: \.directory)
                    HStack {
                        Label("分支：" + (builds.branch.isEmpty ? (builds.draft.directory.isEmpty ? "未选择项目" : "读取中…") : builds.branch), systemImage: "arrow.triangle.branch")
                            .lineLimit(1).truncationMode(.middle).help(builds.branch)
                        Spacer()
                        Button("自动识别环境", action: builds.detectEnvironment).disabled(builds.draft.directory.isEmpty)
                            .help("自动读取 JDK、Android SDK 和 Flavor；不启动 Android Studio")
                    }.font(.caption).foregroundColor(palette.muted)
                    HStack {
                        Picker("Flavor", selection: Binding(get: { builds.draft.selectedVariant?.flavorKey ?? "__manual__" }, set: builds.selectFlavor)) {
                            if builds.draft.selectedVariant == nil { Text(builds.draft.availableVariants.isEmpty ? "尚未读取" : "手动配置").tag("__manual__") }
                            ForEach(flavorOptions) { option in Text(option.flavorLabel).tag(option.flavorKey) }
                        }.accessibilityLabel("选择 Flavor")
                        Picker("构建类型", selection: Binding(get: { builds.draft.selectedVariant?.name ?? "__manual__" }, set: builds.selectVariant)) {
                            if builds.draft.selectedVariant == nil { Text("手动配置").tag("__manual__") }
                            ForEach(buildTypeOptions) { option in Text(option.buildType).tag(option.name) }
                        }.accessibilityLabel("选择构建类型")
                        Button("刷新 Flavor", action: builds.refreshVariants).disabled(builds.draft.javaHome.isEmpty || builds.draft.sdkRoot.isEmpty)
                            .help("源码分支或 Flavor 改变后重新读取；环境未配置时先自动识别环境")
                    }
                    HStack {
                        Text(builds.draft.packageID.isEmpty ? "选择项目后自动识别应用，也可在高级配置中手动填写。" : "应用：" + builds.draft.packageID)
                            .lineLimit(1).truncationMode(.middle).help(builds.draft.packageID).textSelection(.enabled)
                        Spacer()
                        if builds.draft.selectedVariant == nil && !builds.draft.directory.isEmpty {
                            Button("手动配置：" + builds.draft.variant) { advanced = true }
                        } else if builds.draft.selectedVariant?.buildType.lowercased() == "release" {
                            Text("Release 需配置签名").foregroundColor(palette.warning)
                        }
                    }.font(.caption).foregroundColor(palette.muted)
                    DisclosureGroup("高级配置", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("App 包名").frame(width: 85, alignment: .leading)
                                TextField("com.example.app", text: $builds.draft.packageID).accessibilityLabel("本地项目包名")
                            }
                            HStack {
                                Text("模块").frame(width: 85, alignment: .leading)
                                TextField("app", text: $builds.draft.module).accessibilityLabel("构建模块")
                                Text("手填变体")
                                TextField("debug / demoDebug", text: $builds.draft.variant).accessibilityLabel("构建变体")
                            }
                            pathRow("JDK Home", path: $builds.draft.javaHome, field: \.javaHome)
                            pathRow("Android SDK", path: $builds.draft.sdkRoot, field: \.sdkRoot)
                            Toggle("节省内存", isOn: $builds.draft.lowMemory)
                            Text("Gradle 堆上限 3 GB，最多 2 个 worker；总内存还包含编译器等开销。保留增量缓存，构建结束后退出本次 Gradle 进程。")
                                .font(.caption).foregroundColor(palette.muted).fixedSize(horizontal: false, vertical: true)
                            Button("解除关联") { builds.remove(builds.draft.packageID) }.disabled(builds.project(for: builds.draft.packageID) == nil)
                        }.font(.system(size: 12)).padding(.top, 8)
                    }.font(.system(size: 12))
                }.textFieldStyle(.roundedBorder).padding(2)
            }.frame(height: advanced ? 330 : 160).disabled(builds.busy || builds.detecting)
            if builds.detecting {
                HStack { ProgressView().controlSize(.small); Text("正在读取项目环境和 Flavor…"); Button("取消读取", action: builds.cancelDetection) }.font(.caption)
            }
            if let error = builds.configurationError {
                HStack(alignment: .top) {
                    Text(error).lineLimit(3).help(error).textSelection(.enabled)
                    Spacer()
                    Button("检查高级配置") { advanced = true }
                }.font(.caption).foregroundColor(palette.warning)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(builds.busy ? "本次目标：\(builds.activeTarget?.name ?? "")" : "目标手机：\(model.device?.name ?? "未连接")")
                        .help(builds.activeTarget?.serial ?? model.selectedSerial)
                    Text("运行当前已保存代码，覆盖安装并保留应用数据。").font(.caption).foregroundColor(palette.muted)
                }.font(.system(size: 12))
                Spacer()
                if builds.busy { ProgressView().controlSize(.small); Button("取消任务", action: builds.cancel) }
                else {
                    Button("保存关联") { _ = builds.save(builds.draft) }.disabled(builds.detecting)
                    Button("编译并运行") {
                        guard builds.save(builds.draft), let target = model.localBuildTarget else { return }
                        builds.start(builds.draft, target: target)
                    }.buttonStyle(.borderedProminent).disabled(builds.detecting || model.localBuildTarget == nil || model.mirror.installer.isInstalling)
                        .help("保存当前配置，编译并安装到目标手机，然后启动应用")
                }
            }
            Divider()
            HStack {
                Text(builds.failedStage.map { $0.rawValue.replacingOccurrences(of: "中", with: "") + "失败" } ?? builds.stage.rawValue)
                    .font(.headline).foregroundColor(builds.stage == .failed ? palette.warning : palette.accent)
                Text(builds.message).font(.caption).lineLimit(2).help(builds.message).textSelection(.enabled)
                Spacer()
                Button("导出输出", action: builds.exportOutput).disabled(builds.output.isEmpty)
            }
            DetailTextView(text: builds.output, palette: palette, fontSize: appearance.fontSize, find: find, activate: {}, accessibilityLabel: "构建输出")
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.field)
        }.padding(18).background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
            .onAppear { if builds.draft.packageID.isEmpty && !model.selectedPackage.isEmpty { builds.edit(model.selectedPackage) } }
            .task(id: builds.draft.directory) { await builds.refreshBranch() }
            .onChange(of: scenePhase) { if $0 == .active { Task { await builds.refreshBranch() } } }
    }
    private var flavorOptions: [LocalBuildVariant] {
        var seen = Set<String>()
        return builds.draft.availableVariants.filter { seen.insert($0.flavorKey).inserted }
    }
    private var buildTypeOptions: [LocalBuildVariant] {
        guard let selected = builds.draft.selectedVariant else { return [] }
        return builds.draft.availableVariants.filter { $0.flavorKey == selected.flavorKey }
    }
    private func pathRow(_ title: String, path: Binding<String>, field: WritableKeyPath<LocalBuildProject, String>) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 85, alignment: .leading)
            TextField(title, text: path).accessibilityLabel(title)
            Button("选择…") { builds.chooseDirectory(field) }.accessibilityLabel("选择" + title)
        }
    }
}

struct LocalBuildToolbar: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var builds: LocalBuildController
    var compact = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 8) {
            if builds.busy {
                ProgressView().controlSize(.mini)
                Button(compact ? builds.stage.rawValue : "\(builds.stage.rawValue) · \(builds.activeTarget?.name ?? "")") { openWindow(id: "local-build") }.help("查看构建输出 · " + (builds.activeTarget?.name ?? ""))
                Button("取消", action: builds.cancel)
            } else if let project = builds.project(for: model.selectedPackage) {
                Button {
                    if let target = model.localBuildTarget {
                        builds.edit(project.packageID)
                        if !builds.start(project, target: target) { openWindow(id: "local-build") }
                    }
                } label: { Label("编译并运行", systemImage: "play.fill") }
                    .disabled(model.localBuildTarget == nil || builds.detecting || model.mirror.installer.isInstalling)
                Text(project.variant).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: compact ? 100 : 180).help(project.variant)
                Button { builds.edit(project.packageID); openWindow(id: "local-build") } label: { Image(systemName: "gearshape") }.help("本地项目配置与构建输出")
            } else {
                Button { builds.edit(model.selectedPackage); openWindow(id: "local-build") } label: { Label("关联本地项目", systemImage: "hammer") }
            }
            if !builds.busy && builds.stage != .idle {
                Button { openWindow(id: "local-build") } label: {
                    if compact { Image(systemName: "text.alignleft").accessibilityLabel(builds.stage.rawValue + " · 查看构建输出") }
                    else { Text(builds.stage.rawValue + " · 查看输出") }
                }.help(builds.stage.rawValue + " · 查看构建输出")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}
