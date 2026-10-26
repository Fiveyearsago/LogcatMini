import SwiftUI
import LogcatCore

struct ContentView: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var replay: RequestReplayStore
    @ObservedObject var sDecrypt: LogSDecryptionStore
    @ObservedObject private var media: DeviceMediaController
    @ObservedObject private var library: MediaLibrary
    @ObservedObject private var mirror: DeviceMirrorController
    @StateObject private var companion = CatCompanion()
    init(model: LogViewModel, appearance: AppearanceSettings, replay: RequestReplayStore, sDecrypt: LogSDecryptionStore) {
        self.model = model; self.appearance = appearance; self.media = model.media; self.library = model.media.library
        self.replay = replay; self.sDecrypt = sDecrypt; self.mirror = model.mirror
    }
    @AppStorage("layout.sidebarWidth") private var sidebarWidth = 274.0
    @AppStorage("sidebar.favoritesExpanded") private var favoritesExpanded = true
    @AppStorage("sidebar.otherAppsExpanded") private var otherAppsExpanded = true
    @State private var inspectorHeight: CGFloat = 220
    @AppStorage("layout.mirrorWidth") private var mirrorWidth = 330.0
    private enum FilterField: Hashable { case query, tag }
    @FocusState private var filterFocus: FilterField?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    var body: some View {
        GeometryReader { window in
        let sidebarLimit = max(240, min(640, window.size.width - 720))
        HStack(spacing: 0) {
            if !model.logFullscreen && !model.inspectorFullscreen {
                sidebar.frame(width: min(max(240, sidebarWidth), sidebarLimit))
                SidebarDivider(palette: palette) { delta in
                    sidebarWidth = min(sidebarLimit, max(240, sidebarWidth + delta))
                }.frame(width: 7)
            }
            VStack(spacing: 0) {
                if !model.logFullscreen && !model.inspectorFullscreen {
                    header
                    filters
                }
                if model.logFullscreen || model.inspectorFullscreen { compactDeviceToolbar }
                if let message = media.notice { banner(message, color: palette.accent, symbol: "checkmark.circle", dismiss: { media.notice = nil }) }
                if let message = media.error { banner(message, color: palette.warning, dismiss: { media.error = nil }) }
                if let message = library.error { banner(message, color: palette.warning, dismiss: { library.error = nil }) }
                if let message = model.errorMessage { banner(message, color: palette.warning, dismiss: { model.errorMessage = nil }) }
                if let message = model.filterError { banner(message, color: palette.warning, dismiss: nil) }
                HStack(spacing: 0) {
                    GeometryReader { geometry in
                        let height = min(max(150, inspectorHeight), max(150, geometry.size.height - 130))
                        VStack(spacing: 0) {
                            ListSearchHeader(find: model.listFind, palette: palette) { model.activeFindPane = .list }
                                .frame(height: model.inspectorFullscreen ? 0 : nil).clipped()
                                .accessibilityHidden(model.inspectorFullscreen)
                            ZStack {
                                LogTable(entries: model.visible, revision: model.revision, palette: palette, fontSize: appearance.fontSize, visibleColumns: appearance.columns.visibleColumns, filterKey: "\(model.selectedSerial)\u{0}\(model.selectedPackage)\u{0}\(model.minimum.rawValue)\u{0}\(model.query)\u{0}\(model.tag)\u{0}\(model.regex)", follow: $model.follow, selected: $model.selectedLog, find: model.listFind, activate: { model.activeFindPane = .list }, didCopy: { meetCat(.copied) })
                                if model.visible.isEmpty {
                                    VStack(spacing: 13) {
                                        Image(systemName: model.device == nil ? "cable.connector" : "text.alignleft").font(.system(size: appearance.uiSize(32), weight: .light)).foregroundColor(palette.accent)
                                        Text(emptyTitle).font(.system(size: appearance.uiSize(17), weight: .semibold))
                                        Text(emptyHint).font(.system(size: appearance.uiSize(12))).foregroundColor(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                                    }.padding(32).allowsHitTesting(false)
                                }
                            }
                            .frame(height: model.inspectorFullscreen ? 0 : nil).clipped()
                            .accessibilityHidden(model.inspectorFullscreen)
                            if let entry = model.selectedLog {
                                InspectorDivider(palette: palette) { delta in
                                    inspectorHeight = min(max(150, height + delta), max(150, geometry.size.height - 130))
                                }.frame(height: model.inspectorFullscreen ? 0 : 10).clipped()
                                    .accessibilityHidden(model.inspectorFullscreen).allowsHitTesting(!model.inspectorFullscreen)
                                LogInspector(entry: entry, palette: palette, appearance: appearance, fullscreen: $model.inspectorFullscreen, find: model.detailFind, activate: { model.activeFindPane = .detail },
                                             copy: { text in
                                                 if model.copyDetail(text) { meetCat(.copied) }
                                             }, close: { model.selectedLog = nil }, simulate: {
                                                 replay.importLog(entry, context: model.requestContext(for: entry))
                                                 openWindow(id: "request-replay")
                                             }, decryptS: {
                                                 sDecrypt.importLog(entry)
                                                 openWindow(id: "s-decryption")
                                             }, showFormatted: $model.detailFormatted, canFormat: $model.canFormatDetail)
                                    .frame(height: model.inspectorFullscreen ? geometry.size.height : height - 10)
                            }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        CatCompanionOverlay(companion: companion, palette: palette)
                            .padding(18)
                    }
                    if model.mirrorShown && !model.inspectorFullscreen {
                        let limit = max(260, min(560, window.size.width - (model.logFullscreen ? 420 : min(max(240, sidebarWidth), sidebarLimit) + 427)))
                        SidebarDivider(palette: palette, accessibilityTitle: "调整投屏宽度") { delta in
                            mirrorWidth = max(260, min(limit, mirrorWidth - delta))
                        }.frame(width: 7)
                        DeviceMirrorPanel(mirror: mirror, media: media, palette: palette,
                                          canCapture: model.device?.ready == true && model.adbPath != nil,
                                          takeScreenshot: { model.takeScreenshot() }, copyScreenshot: { model.takeScreenshot(copy: true) }, toggleRecording: model.toggleRecording,
                                          reconnect: model.connectMirror, close: model.closeMirror)
                            .frame(width: max(260, min(limit, mirrorWidth)))
                    }
                }
                if !model.inspectorFullscreen { footer }
            }
        }
        .foregroundColor(palette.text)
        .background(palette.canvas)
        .tint(palette.accent)
        }
        .onDisappear { companion.dismiss() }
        .onChange(of: model.inspectorFullscreen) { _ in companion.dismiss() }
        .onChange(of: model.logFullscreen) { _ in companion.dismiss() }
        .onChange(of: model.completedCaptureCount) { _ in
            if model.totalCount >= 10 { meetCat(.finishedCapture) }
        }
        .task(id: "\(model.selectedSerial)\u{0}\(model.selectedPackage)\u{0}\(model.query)\u{0}\(model.tag)\u{0}\(model.minimum.rawValue)\u{0}\(model.regex)") {
            guard !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !model.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Wait for typing and the existing filter debounce, without watching log traffic.
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard !Task.isCancelled, model.totalCount >= 20 else { return }
            if model.filterError != nil {
                meetCat(.tangledRegex)
            } else if model.visible.isEmpty {
                meetCat(.noMatches)
            } else if model.visible.count <= model.totalCount / 3 {
                meetCat(.filtered)
            }
        }
        .task(id: "\(model.paused)\u{0}\(model.running)\u{0}\(model.selectedSerial)\u{0}\(model.selectedPackage)") {
            guard model.paused, model.running, !model.visible.isEmpty else { return }
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard !Task.isCancelled, model.paused, model.running, !model.visible.isEmpty else { return }
            meetCat(.pausedReading)
        }
    }
    private func meetCat(_ encounter: CatCompanion.Encounter) {
        guard scenePhase == .active else { return }
        companion.encounter(encounter)
    }
    private var emptyTitle: String {
        if model.adbPath == nil { return "连接你的 Android 工作流" }
        if model.devices.isEmpty { return "等待手机连接" }
        if model.device?.state == "unauthorized" { return "请在手机上允许 USB 调试" }
        if !model.query.isEmpty || !model.tag.isEmpty || model.minimum != .verbose { return "没有匹配的日志" }
        return model.running ? "正在等待日志" : "准备好开始了"
    }
    private var emptyHint: String {
        if model.adbPath == nil { return "选择已安装的 ADB，然后连接手机。所有日志都保留在本机。" }
        if model.devices.isEmpty { return "通过 USB 连接手机，打开开发者选项中的 USB 调试，并允许这台 Mac。也支持已配对的无线 ADB 设备。" }
        if !model.query.isEmpty || !model.tag.isEmpty || model.minimum != .verbose { return "尝试调整等级、Tag 或搜索关键词。" }
        return model.running ? "在手机上操作所选 App，日志会实时出现在这里。" : "选择设备和应用，点击右上角「开始采集」。"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "terminal.fill").font(.system(size: appearance.uiSize(25))).foregroundColor(palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Logcat Mini").font(.system(size: appearance.uiSize(19), weight: .bold))
                    Text("少一点噪声，多一点线索").font(.system(size: appearance.uiSize(10))).foregroundColor(palette.muted)
                }
            }.padding(.horizontal, 20).padding(.vertical, 25)
            HStack {
                sectionLabel("设备")
                Spacer()
                Button { Task { await model.refreshDevices(); await model.refreshPackages() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundColor(palette.muted).help("刷新设备和应用")
            }.padding(.horizontal, 20).padding(.bottom, 10)
            if model.devices.isEmpty {
                Label("未连接手机", systemImage: "iphone.slash").foregroundColor(palette.muted).font(.system(size: appearance.uiSize(12))).padding(.horizontal, 20).padding(.vertical, 16)
            }
            ForEach(model.devices) { device in
                Button { Task { await model.selectDevice(device.id) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone").font(.system(size: appearance.uiSize(20))).foregroundColor(device.ready ? palette.accent : palette.warning)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.system(size: appearance.uiSize(12), weight: .semibold)).foregroundColor(palette.text)
                            Text(device.ready ? device.id : (device.state == "unauthorized" ? "请在手机上授权" : "设备离线"))
                                .font(.system(size: appearance.uiSize(10), design: .monospaced)).foregroundColor(palette.muted)
                        }
                        Spacer()
                        Circle().fill(device.ready ? palette.accent : palette.warning).frame(width: 6, height: 6)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 9).fill(model.selectedSerial == device.id ? palette.accent.opacity(0.09) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.selectedSerial == device.id ? palette.accent.opacity(0.25) : .clear))
                }.buttonStyle(.plain)
                    .accessibilityLabel("切换到设备 \(device.name) · \(device.id)")
                    .accessibilityValue(model.selectedSerial == device.id ? "当前设备" : "未选中")
                    .help("切换日志与投屏到 \(device.name)（\(device.id)）")
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            Rectangle().fill(palette.line).frame(height: 1).padding(.vertical, 17)
            HStack {
                sectionLabel("应用")
                Spacer()
                if model.loadingApps { ProgressView().controlSize(.small).scaleEffect(0.65) }
                else { Text("\(model.packages.count)").font(.system(size: appearance.uiSize(11), design: .monospaced)).foregroundColor(palette.muted) }
            }.padding(.horizontal, 20)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(palette.muted)
                TextField("搜索包名或收藏名称", text: $model.appSearch).textFieldStyle(.plain).font(.system(size: appearance.uiSize(12)))
                if !model.appSearch.isEmpty { Button { model.appSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundColor(palette.muted) }
            }.padding(9).background(palette.field).cornerRadius(6).padding(.horizontal, 16).padding(.vertical, 12)
            appRow(id: "", title: "全部应用", subtitle: "查看设备的所有日志", symbol: "square.grid.2x2")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    Button { favoritesExpanded.toggle() } label: {
                        HStack {
                            Image(systemName: favoritesExpanded ? "chevron.down" : "chevron.right").frame(width: 10)
                            Label("收藏夹", systemImage: "star.fill")
                            Spacer()
                            if model.loadingFavoriteMetadata { ProgressView().controlSize(.mini) }
                            if let notice = model.favoriteMetadataNotice { Image(systemName: "exclamationmark.circle").help(notice) }
                            Text("\(model.favorites.packageIDs.count)")
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(favoritesExpanded ? "折叠收藏夹" : "展开收藏夹")
                        .font(.system(size: appearance.uiSize(11), weight: .semibold)).foregroundColor(palette.muted)
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 5)
                    if favoritesExpanded {
                        if model.matchingFavoriteIDs.isEmpty {
                            Text(model.favorites.packageIDs.isEmpty ? "点击应用右侧 ☆ 收藏常用包名" : "没有匹配的收藏")
                                .font(.system(size: appearance.uiSize(11))).foregroundColor(palette.muted)
                                .padding(.horizontal, 20).padding(.vertical, 8)
                        }
                        ForEach(model.matchingFavoriteIDs, id: \.self) { packageID in
                            let listed = model.isPackageListed(packageID)
                            appRow(id: packageID, title: packageID.split(separator: ".").suffix(2).joined(separator: "."), subtitle: packageID, symbol: "app.dashed", available: listed)
                        }
                    }
                    Button { otherAppsExpanded.toggle() } label: {
                        HStack {
                            Image(systemName: otherAppsExpanded ? "chevron.down" : "chevron.right").frame(width: 10)
                            Text("其他应用")
                            Spacer()
                            Text("\(model.matchingApps.count)")
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(otherAppsExpanded ? "折叠其他应用" : "展开其他应用")
                        .font(.system(size: appearance.uiSize(11), weight: .semibold)).foregroundColor(palette.muted)
                        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 5)
                    if otherAppsExpanded {
                        ForEach(model.matchingApps) { app in
                            appRow(id: app.id, title: app.shortName, subtitle: app.id, symbol: "app.dashed")
                        }
                    }
                }.padding(.vertical, 5)
            }
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 8) {
                Button { openWindow(id: "settings") } label: {
                    ShortcutLabel("设置", systemImage: "gearshape", shortcut: .settings)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("外观、字号、显示列与保存位置 · ⌘,")
                if companion.discovered {
                    Button(action: companion.openDiary) {
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 12)).foregroundColor(palette.muted)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("猫的值班日记")
                        .accessibilityLabel("打开猫的值班日记")
                }
                Spacer()
                Label(model.adbPath == nil ? "ADB 未配置" : "ADB 已就绪",
                      systemImage: model.adbPath == nil ? "exclamationmark.circle" : "checkmark.shield")
                    .font(.system(size: appearance.uiSize(10))).foregroundColor(model.adbPath == nil ? palette.warning : palette.muted)
                    .lineLimit(1).help(model.adbPath ?? "请在设置中选择 Android SDK 中的 adb")
            }.padding(.horizontal, 18).padding(.vertical, 14)
        }.background(palette.panel)
    }
    private func sectionLabel(_ title: String) -> some View { Text(title).font(.system(size: appearance.uiSize(11), weight: .semibold)).foregroundColor(palette.muted) }
    private func appRow(id: String, title: String, subtitle: String, symbol: String, available: Bool = true) -> some View {
        AppListRow(model: model, builds: model.builds, appearance: appearance, id: id, title: title, subtitle: subtitle, symbol: symbol, available: available)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                titleRow(compact: false)
                titleRow(compact: true)
            }
            ViewThatFits(in: .horizontal) {
                deviceActionRow(compact: false)
                deviceActionRow(compact: true)
            }
        }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 10)
    }
    private func titleRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Text(model.favoriteMetadata[model.selectedPackage]?.label ?? model.sessionTitle)
                .font(.system(size: appearance.uiSize(14), weight: .semibold))
                .lineLimit(1).truncationMode(.middle).frame(minWidth: 60, maxWidth: 240, alignment: .leading)
                .help(model.sessionTitle)
            captureStatus
            Spacer(minLength: 0)
            readingControls(compact: compact)
            pauseControl
            if !compact {
                Button(action: model.clear) { Label("清空", systemImage: "trash") }.help("清空当前视图 · ⌘K；不清除手机日志")
            }
            logActionsMenu(includeClear: compact)
            fullscreenControl(compact: compact)
            captureControl
        }.font(.system(size: appearance.uiSize(11))).buttonStyle(.borderless)
    }
    private var captureStatus: some View {
        Text(model.running ? (model.paused ? "仍在采集" : "采集中") : "已停止采集")
            .font(.system(size: appearance.uiSize(10), weight: .medium))
            .foregroundColor(model.running ? (model.paused ? palette.warning : palette.accent) : palette.muted)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(palette.field)).fixedSize()
    }
    private var pauseControl: some View {
        Button(action: model.togglePause) {
            Label(model.paused ? "恢复滚动" : "暂停滚动", systemImage: model.paused ? "play.fill" : "pause.fill")
                .fixedSize().foregroundColor(model.paused ? palette.warning : palette.text)
        }.disabled(!model.running && !model.paused)
            .help(model.paused ? "恢复列表显示，新收到的日志会出现在列表中 · ⌘P" : "冻结当前列表，后台继续采集日志 · ⌘P")
    }
    private var captureControl: some View {
        Button(action: model.toggleCapture) {
            Label(model.running ? "停止采集" : "开始采集", systemImage: model.running ? "stop.fill" : "play.fill").fixedSize()
        }.disabled(!model.running && !model.canStart).buttonStyle(.bordered)
            .help(model.running ? "停止接收手机日志，保留当前记录 · ⌘R" : "开始接收手机日志 · ⌘R")
    }
    private func logActionsMenu(includeClear: Bool) -> some View {
        Menu {
            if includeClear { Button("清空当前视图", action: model.clear) }
            Button("导出筛选日志…", action: model.export).disabled(model.visible.isEmpty)
        } label: { Image(systemName: "ellipsis").frame(width: 22) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多日志操作").help("导出日志 · ⇧⌘S" + (includeClear ? "；清空视图 · ⌘K" : ""))
    }
    private func deviceActionRow(compact: Bool) -> some View {
        HStack(spacing: 12) {
            deviceMenu
            toolbarDivider
            mediaControls(compact: compact)
            toolbarDivider
            LocalBuildToolbar(model: model, builds: model.builds, compact: compact)
            Spacer(minLength: 0)
        }.font(.system(size: appearance.uiSize(11))).buttonStyle(.borderless).lineLimit(1)
    }
    private var toolbarDivider: some View { Rectangle().fill(palette.line).frame(width: 1, height: 18) }
    private var filters: some View {
        filterInputs.padding(.horizontal, 18).padding(.bottom, 10)
            .onChange(of: filterFocus) { if $0 == nil { model.rememberFilter() } }
            .onDisappear { model.rememberFilter() }
    }
    private var filterInputs: some View {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundColor(palette.muted).accessibilityLabel("过滤")
                    TextField(model.regex ? "输入过滤正则表达式…" : "过滤日志、Tag、PID；多个关键词用 | 分隔", text: $model.query).textFieldStyle(.plain)
                        .focused($filterFocus, equals: .query).onSubmit { model.rememberFilter() }
                        .help(model.regex ? "按完整正则表达式匹配，忽略大小写" : "用 | 分隔多个关键词，匹配任意一个即可；例如：登录|支付|请求失败")
                    if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundColor(palette.muted) }
                    Button { model.regex.toggle() } label: { Text(".*").font(.system(size: appearance.uiSize(13), weight: .bold, design: .monospaced)).foregroundColor(model.regex ? palette.accent : palette.muted).padding(.horizontal, 5) }.buttonStyle(.plain).help("正则表达式搜索（忽略大小写）")
                    Button(action: model.toggleFilterFavorite) {
                        Image(systemName: model.filterHistory.isFavorite(model.currentFilter) ? "star.fill" : "star")
                            .foregroundColor(model.filterHistory.isFavorite(model.currentFilter) ? palette.accent : palette.muted)
                    }.buttonStyle(.plain).disabled(!model.currentFilter.canSave)
                        .help(model.filterHistory.isFavorite(model.currentFilter) ? "取消收藏当前过滤条件" : "收藏当前过滤条件")
                        .accessibilityLabel("收藏过滤条件")
                    filterHistoryMenu
                }.padding(10).background(palette.field).cornerRadius(6)
                tagFilter.frame(width: 160)
                levelFilter
            }.font(.system(size: appearance.uiSize(12)))
    }
    private var levelFilter: some View {
        HStack(spacing: 6) {
            Text("等级").foregroundColor(palette.muted)
            Picker("日志等级", selection: $model.minimum) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level == .verbose ? "全部" : level.title + "+").tag(level)
                }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel("日志等级")
                .help("显示所选等级及以上的日志；全部包含 Verbose")
        }.padding(.horizontal, 10).padding(.vertical, 8).background(palette.field).cornerRadius(6).fixedSize()
    }
    private var tagFilter: some View {
        HStack(spacing: 8) {
            Text("TAG").font(.system(size: appearance.uiSize(9), weight: .bold, design: .monospaced)).foregroundColor(palette.muted)
            TextField("Tag1|Tag2", text: $model.tag).textFieldStyle(.plain)
                .focused($filterFocus, equals: .tag).onSubmit { model.rememberFilter() }
                .help("多个 Tag 用 | 分隔，匹配任意一个；同时满足关键词和等级条件")
                .accessibilityLabel("Tag 过滤")
            if !model.tag.isEmpty { Button { model.tag = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundColor(palette.muted) }
        }.padding(10).background(palette.field).cornerRadius(6)
    }
    private var deviceMenu: some View {
        Menu {
            if model.devices.isEmpty { Text("未连接设备") }
            ForEach(model.devices) { device in
                Button { Task { await model.selectDevice(device.id) } } label: {
                    Text((model.selectedSerial == device.id ? "✓ " : "") + device.name + " · " + device.id + (device.ready ? "" : "（\(device.state)）"))
                }
            }
            Divider()
            Button("刷新设备") { Task { await model.refreshDevices() } }
        } label: {
            Label(model.device.map { $0.name + ($0.ready ? "" : " · 离线") } ?? "选择设备", systemImage: "iphone")
                .lineLimit(1).frame(maxWidth: 160)
        }.fixedSize().help("当前设备：\(model.selectedSerial)；点击切换，日志按设备保留到退出")
            .accessibilityLabel("切换设备")
    }
    private func mediaControls(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Button(action: model.toggleMirror) {
                actionLabel(model.mirrorShown ? "收起投屏" : "手机投屏", symbol: "iphone", compact: compact)
            }.help("在日志右侧显示并操控当前手机").accessibilityLabel(model.mirrorShown ? "收起投屏" : "手机投屏")
            ScreenshotControl(takingScreenshot: media.takingScreenshot, canCapture: model.device?.ready == true && model.adbPath != nil,
                              compact: compact, save: { model.takeScreenshot() }, copy: { model.takeScreenshot(copy: true) })
            if media.recording || media.saving {
                Button(action: media.stopRecording) {
                    actionLabel(media.saving ? "保存录屏…" : "停止录屏 \(media.elapsedText)", symbol: "stop.circle.fill", shortcut: .recording, compact: compact)
                }.disabled(media.saving).foregroundColor(palette.error)
                    .help("正在录制：\(media.recordingDevice)；切换设备不会改变此录制的目标")
                if compact { Text(media.elapsedText).monospacedDigit().foregroundColor(palette.error) }
                else { Text(media.recordingDevice).lineLimit(1).truncationMode(.middle).frame(maxWidth: 145).foregroundColor(palette.muted) }
            } else if media.canRetry {
                Button(action: media.retrySave) { actionLabel("重试保存录屏", symbol: "arrow.clockwise", compact: compact) }.help("重试保存录屏 · " + media.recordingDevice)
                Button(action: media.dismissRetry) { actionLabel("取消重试", symbol: "xmark.circle", compact: compact) }.help("取消重试，保留 Mac 中的临时文件，允许开始新录屏")
            } else {
                Button {
                    if let path = model.adbPath, let device = model.device { media.startRecording(path: path, device: device) }
                } label: { actionLabel("录屏", symbol: "record.circle", shortcut: .recording, compact: compact) }
                    .disabled(model.device?.ready != true).help("录制当前 Android 设备画面为 MP4，无声音，最长 3 分钟后自动保存 · ⇧⌘R")
            }
            Button { openWindow(id: "media-history") } label: {
                actionLabel("媒体历史", symbol: "photo.stack", shortcut: .history, compact: compact)
            }.help("查看、预览和打开历史文件 · ⌘⇧H")
            if media.lastSaved != nil {
                Button(action: media.revealSaved) { Image(systemName: "folder") }.help("在 Finder 中显示最近保存的截图或录屏").accessibilityLabel("显示保存文件")
            }
        }.buttonStyle(.borderless).fixedSize()
    }
    private var compactDeviceToolbar: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                fullscreenToolbarRow(compact: false)
                fullscreenToolbarRow(compact: true)
            }
            if !model.inspectorFullscreen { filterInputs }
        }.padding(.horizontal, 12).padding(.vertical, 6).background(palette.panel)
            .onChange(of: filterFocus) { if $0 == nil { model.rememberFilter() } }
            .onDisappear { model.rememberFilter() }
    }
    private func fullscreenToolbarRow(compact: Bool) -> some View {
        HStack(spacing: 12) {
            deviceMenu
            Spacer(minLength: 0)
            mediaControls(compact: compact)
            if !model.inspectorFullscreen {
                toolbarDivider
                readingControls(compact: compact)
                pauseControl
                logActionsMenu(includeClear: true)
                fullscreenControl(compact: compact)
                captureControl
            }
        }.font(.system(size: appearance.uiSize(11)))
    }
    @ViewBuilder private func actionLabel(_ title: String, symbol: String, shortcut: AppShortcut? = nil, compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(minWidth: 22)
                .accessibilityLabel(title).help(title + (shortcut.map { " · " + $0.label } ?? ""))
        } else {
            Label(title, systemImage: symbol).fixedSize()
        }
    }
    private func readingControls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { model.openFind(.list) } label: { actionLabel("查找", symbol: "magnifyingglass", shortcut: .find, compact: compact) }
                .buttonStyle(.borderless).help("查找列表 · ⌘F").accessibilityLabel("查找日志列表")
            followControl(compact: compact)
        }.fixedSize()
    }
    private func fullscreenControl(compact: Bool) -> some View {
        Button(action: model.toggleLogFullscreen) {
            actionLabel(model.logFullscreen ? "恢复菜单" : "日志全屏", symbol: model.logFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", shortcut: .listFullscreen, compact: compact)
        }.buttonStyle(.bordered).help(model.logFullscreen ? "恢复菜单 · ⌘⇧F；也可按 Esc" : "日志全屏 · ⌘⇧F；Esc 恢复菜单")
            .accessibilityLabel(model.logFullscreen ? "恢复菜单" : "日志全屏")
    }
    private var filterHistoryMenu: some View {
        Menu {
            if model.filterHistory.entries.isEmpty { Text("暂无过滤历史，输入后按回车保存") }
            if !model.filterHistory.favorites.isEmpty {
                Section("收藏") {
                    ForEach(model.filterHistory.favorites) { entry in
                        Button("★ " + entry.filter.title) { model.restoreFilter(entry.filter) }
                    }
                }
            }
            if !model.filterHistory.recent.isEmpty {
                Section("最近使用") {
                    ForEach(model.filterHistory.recent) { entry in
                        Button(entry.filter.title) { model.restoreFilter(entry.filter) }
                    }
                }
                Divider()
                Button("清空历史（保留收藏）", action: model.clearFilterHistory)
            }
        } label: { Text("历史 / 收藏") }
            .fixedSize().help("恢复关键词、Tag、等级和正则开关；最近 30 条，收藏长期保留")
    }
    private func followControl(compact: Bool) -> some View {
        Button(action: model.toggleFollow) {
            Label(model.isFollowing ? "跟随最新 · 开" : "跟随最新 · 关", systemImage: model.isFollowing ? "checkmark.circle.fill" : "circle")
                .fixedSize().font(.system(size: appearance.uiSize(11), weight: .semibold))
                .foregroundColor(model.isFollowing ? palette.onAccent : palette.muted)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(model.isFollowing ? palette.accent : palette.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.isFollowing ? palette.accent : palette.line, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("跟随最新").accessibilityValue(model.isFollowing ? "开启" : "关闭")
            .help(model.paused ? "恢复列表显示并跟随最新日志 · ⌘L" : model.isFollowing ? "新日志自动滚到末尾；滚动查看历史会关闭跟随 · ⌘L" : "保持当前阅读位置；点击或按 ⌘L 跟随最新")
    }
    private func banner(_ text: String, color: Color, symbol: String = "exclamationmark.circle", dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
            Text(text).lineLimit(3).textSelection(.enabled)
            Spacer()
            if let dismiss = dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }.font(.system(size: appearance.uiSize(11))).foregroundColor(color).padding(12).background(color.opacity(0.08))
    }
    private var footer: some View {
        HStack(spacing: 9) {
            if model.logFullscreen {
                captureStatus
                Text(model.favoriteMetadata[model.selectedPackage]?.label ?? model.sessionTitle)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .leading)
                    .help(model.sessionTitle)
                if model.minimum != .verbose || !model.query.isEmpty || !model.tag.isEmpty {
                    Button("已筛选") { model.logFullscreen = false }
                        .buttonStyle(.borderless).foregroundColor(palette.accent).help("恢复菜单，查看当前筛选条件")
                }
            }
            Text(model.paused ? "已暂停滚动 · \(model.running ? "仍在采集" : "已停止采集") · 新收到 \(model.receivedWhilePaused.formatted()) 条" : "\(model.visible.count.formatted()) 条匹配 / 缓存 \(model.totalCount.formatted()) 条")
                .foregroundColor(model.paused ? palette.warning : palette.muted)
                .lineLimit(1).help("当前匹配 \(model.visible.count.formatted()) 条；缓存 \(model.totalCount.formatted()) 条；暂停期间收到 \(model.receivedWhilePaused.formatted()) 条")
            Text("\(model.errorCount.formatted()) 条错误").foregroundColor(model.errorCount > 0 ? palette.error : palette.muted).fixedSize()
            if model.evicted > 0 { Text("· 已轮换 \(model.evicted.formatted()) 条").foregroundColor(palette.muted) }
            Spacer()
            if !model.logFullscreen {
                Text(model.notice).foregroundColor(palette.muted).lineLimit(1).truncationMode(.middle).help(model.notice)
            }
        }.font(.system(size: appearance.uiSize(10))).padding(.horizontal, 18).padding(.vertical, 10).background(palette.panel)
    }
}
