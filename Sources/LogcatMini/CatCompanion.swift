import SwiftUI

/// A window-local companion. It never reads or writes the log stream.
@MainActor final class CatCompanion: ObservableObject {
    enum Presentation { case peek, diary, box }
    enum Encounter {
        case filtered, copied, finishedCapture, noMatches, tangledRegex, pausedReading
        var message: String {
            switch self {
            case .filtered: return "范围缩小了，\n线索露出小尾巴。"
            case .copied: return "线索装好了，\n拿去和 AI 对对口供。"
            case .finishedCapture: return "这一轮辛苦啦，\n伸个懒腰再继续。"
            case .noMatches: return "线索藏得有点深，\n我也来找找。"
            case .tangledRegex: return "括号绕成毛线了，\n陪你慢慢理一理。"
            case .pausedReading: return "你慢慢看，\n我在旁边眯一会儿。"
            }
        }
        var mood: DutyCatMood {
            switch self {
            case .noMatches: return .detective
            case .tangledRegex: return .tangled
            case .pausedReading: return .sleepy
            default: return .curious
            }
        }
        var footer: String {
            switch self {
            case .noMatches: return "换个关键词，也许就在下一爪。"
            case .tangledRegex: return "毛线归我，表达式归你。"
            case .pausedReading: return "列表歇一歇，日志还在采集。"
            default: return "抓到一只正在巡逻的猫。"
            }
        }
    }
    @Published private(set) var presentation: Presentation?
    @Published private(set) var discovered: Bool
    @Published private(set) var entryIndex = 0
    @Published private(set) var visit = UUID()
    @Published private(set) var greeting = "代码交给 AI，\n我陪你盯日志。"
    @Published private(set) var activeEncounter = Encounter.filtered
    @Published private(set) var boxOpen = false
    @Published private(set) var boxIndex = 0
    private let defaults: UserDefaults
    private let clock: () -> Date
    private var unreadEntries: [Int] = []
    private var unopenedBoxes: [Int] = []

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        discovered = defaults.bool(forKey: "easterEgg.catDiscovered")
    }

    /// Called only after meaningful user actions, never from incoming log batches.
    func encounter(_ action: Encounter) {
        guard presentation == nil else { return }
        let now = clock()
        if let last = defaults.object(forKey: "easterEgg.catLastVisit") as? Date,
           now.timeIntervalSince(last) < 30 * 60 { return }
        let day = Calendar.current.startOfDay(for: now)
        let previousDay = defaults.object(forKey: "easterEgg.catVisitDay") as? Date
        let count = previousDay == day ? defaults.integer(forKey: "easterEgg.catDailyVisits") : 0
        guard count < 3 else { return }
        greeting = action.message
        activeEncounter = action
        discover()
        defaults.set(now, forKey: "easterEgg.catLastVisit")
        defaults.set(day, forKey: "easterEgg.catVisitDay")
        defaults.set(count + 1, forKey: "easterEgg.catDailyVisits")
        visit = UUID()
        presentation = .peek
    }

    func openDiary() {
        discover()
        nextEntry()
        defaults.set(clock(), forKey: "easterEgg.catLastVisit")
        visit = UUID()
        presentation = .diary
    }

    func nextEntry() {
        // A shuffled deck keeps each page fresh without repeating at the seam.
        if unreadEntries.isEmpty {
            unreadEntries = Array(Self.entries.indices).shuffled()
            if unreadEntries.last == entryIndex { unreadEntries.swapAt(0, unreadEntries.count - 1) }
        }
        entryIndex = unreadEntries.removeLast()
    }

    func openBox() {
        boxOpen = false
        visit = UUID()
        presentation = .box
    }

    func toggleBox() {
        if !boxOpen {
            if unopenedBoxes.isEmpty {
                unopenedBoxes = Array(Self.boxNotes.indices).shuffled()
                if unopenedBoxes.last == boxIndex { unopenedBoxes.swapAt(0, unopenedBoxes.count - 1) }
            }
            boxIndex = unopenedBoxes.removeLast()
        }
        boxOpen.toggle()
    }

    func dismiss() {
        if presentation != nil { defaults.set(clock(), forKey: "easterEgg.catLastVisit") }
        presentation = nil
    }

    private func discover() {
        guard !discovered else { return }
        discovered = true
        defaults.set(true, forKey: "easterEgg.catDiscovered")
    }

    struct Entry {
        let title: String
        let text: String
        let footer: String
    }

    static let entries: [Entry] = [
        .init(title: "验收搭子", text: "AI 说修好了。\n我先蹲一会儿日志。", footer: "尾巴可以摇，验收不能急。"),
        .init(title: "翻译工作", text: "AI 在解释这段日志。\n我在观察它的表情。", footer: "分工明确，各有所长。"),
        .init(title: "三方协作", text: "AI 写代码，你拿主意。\n我负责在旁边点头。", footer: "偶尔也负责踩一下键盘。"),
        .init(title: "午睡申请", text: "代码已经写完了。\n编译还够我睡一觉。", footer: "呼噜声不计入构建时间。"),
        .init(title: "线索收藏", text: "十万行里找到的那一行，\n比纸箱里的阳光还珍贵。", footer: "今天也有认真找线索。"),
        .init(title: "神秘现象", text: "刚想给你看，Bug 就不见了。\n它可能也有点怕生。", footer: "下次悄悄靠近。"),
        .init(title: "上下文管理", text: "AI 的上下文满了。\n我的纸箱也满了。", footer: "都装着暂时舍不得丢的东西。"),
        .init(title: "小改一下", text: "你说：小改一下。\nAI 说：顺手重构好了。", footer: "我默默抱紧了回滚按钮。"),
        .init(title: "网络观察", text: "请求已经发出去了。\n我去门口接一下响应。", footer: "希望带回来的不是超时。"),
        .init(title: "小小提醒", text: "眼睛借我保管十秒，\n你去看看窗外。", footer: "下一条线索，等你回来。"),
        .init(title: "深夜值班", text: "屏幕亮着，\n就有一只猫陪你。", footer: "不过，明天再修也可以。"),
        .init(title: "下班记录", text: "今天又少了一个 Bug，\n多了一点点安心。", footer: "辛苦啦，记得伸个懒腰。")
    ]

    struct BoxNote {
        let mood: DutyCatMood
        let text: String
        let footer: String
    }
    static let boxNotes: [BoxNote] = [
        .init(mood: .sleepy, text: "Bug 没看见，\n先抓到一只打盹的猫。", footer: "它说自己在等 AI 编译。"),
        .init(mood: .tangled, text: "找到一团毛线，\n和它的神秘依赖。", footer: "猫猫声明：只是顺手重构了一下。"),
        .init(mood: .detective, text: "你在找 Bug，\n它在找小鱼干。", footer: "同一个纸箱，两份待办清单。")
    ]
}

struct CatCompanionOverlay: View {
    @ObservedObject var companion: CatCompanion
    let palette: ThemePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var hovering = false

    var body: some View {
        Group {
            if let presentation = companion.presentation {
                CatCompanionCard(companion: companion, palette: palette)
                    .onHover { hovering = $0 }
                    .transition(reduceMotion ? .opacity : .offset(y: 28).combined(with: .opacity))
                    .task(id: AutoHideKey(visit: companion.visit, hovering: hovering, presentation: presentation)) {
                        guard presentation == .peek, !hovering else { return }
                        // Hovering pauses the visit; opening the diary cancels this task.
                        do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                        guard !Task.isCancelled else { return }
                        companion.dismiss()
                    }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.52, dampingFraction: 0.8), value: companion.presentation)
        .onChange(of: scenePhase) { phase in
            if phase != .active { companion.dismiss() }
        }
        .onChange(of: companion.presentation) { value in
            if value == nil { hovering = false }
        }
    }

    private struct AutoHideKey: Equatable {
        let visit: UUID
        let hovering: Bool
        let presentation: CatCompanion.Presentation
    }
}

private struct CatCompanionCard: View {
    @ObservedObject var companion: CatCompanion
    let palette: ThemePalette
    private var diary: Bool { companion.presentation == .diary }
    private var box: Bool { companion.presentation == .box }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var petting = false
    private var ink: Color { palette.dark ? Color(red: 0.94, green: 0.9, blue: 0.82) : Color(red: 0.28, green: 0.25, blue: 0.22) }
    private var secondaryInk: Color { palette.dark ? Color(red: 0.72, green: 0.74, blue: 0.71) : Color(red: 0.48, green: 0.45, blue: 0.40) }
    private var paper: Color { palette.dark ? Color(red: 0.16, green: 0.21, blue: 0.23) : Color(red: 1, green: 0.98, blue: 0.93) }
    private var accent: Color { palette.dark ? Color(red: 0.58, green: 0.83, blue: 0.75) : Color(red: 0.24, green: 0.47, blue: 0.42) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(box ? "HANDLE WITH PAWS" : diary ? "ON PAW DUTY" : "OH, HI THERE")
                        .font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1.8)
                    Text(box ? "纸箱里有动静" : diary ? "认真值班中" : "被你发现啦")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundColor(secondaryInk)
                .padding(8)
                .background(paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 18).padding(.leading, 12)
                Spacer(minLength: 0)
                Button { if box { companion.toggleBox() } else { companion.openDiary() } } label: {
                    Group {
                        if box {
                            CatCardboardHideout(open: companion.boxOpen, mood: CatCompanion.boxNotes[companion.boxIndex].mood, reduceMotion: reduceMotion)
                        } else {
                            DutyCatIllustration(petted: petting, reduceMotion: reduceMotion, mood: diary ? .curious : companion.activeEncounter.mood)
                        }
                    }
                        .frame(width: 174, height: 140)
                        .offset(y: arrived || reduceMotion ? 0 : 112)
                        .rotationEffect(.degrees(arrived || reduceMotion ? 0 : -8), anchor: .bottom)
                }
                .buttonStyle(.plain)
                .onHover { petting = $0 }
                .accessibilityLabel(box ? (companion.boxOpen ? "合上猫咪的纸箱" : "打开猫咪的纸箱") : "值班猫，点击翻开日记")
                .help(box ? "看看纸箱里的小秘密" : "摸摸猫，翻开它的值班日记")
                .padding(.trailing, 12)
            }
            .frame(height: 146, alignment: .bottom).clipped()
            .accessibilityElement(children: .contain)
            note
                .overlay(alignment: .topTrailing) {
                    // Paws sit above the notebook edge, making the peek feel physical.
                    if !box {
                        DutyCatPaws()
                            .frame(width: 174, height: 24)
                            .padding(.trailing, 12).offset(y: -9).allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        .frame(width: 310)
        .foregroundColor(ink)
        .shadow(color: .black.opacity(palette.dark ? 0.23 : 0.1), radius: 15, x: 0, y: 8)
        .task {
            withAnimation(reduceMotion ? nil : .spring(response: 0.72, dampingFraction: 0.7).delay(0.08)) { arrived = true }
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "pawprint.fill").font(.system(size: 11))
                Text(box ? "薛定谔的纸箱" : diary ? "猫的值班日记" : "一位毛茸茸的同事")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: companion.dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Circle())
                }.buttonStyle(.plain).foregroundColor(secondaryInk)
                    .accessibilityLabel("让值班猫休息").help("让值班猫休息")
            }.foregroundColor(accent)
            Rectangle().fill(accent.opacity(0.16)).frame(height: 1).padding(.top, 7).padding(.bottom, 13)
            if box {
                boxEntry
            } else if diary {
                diaryEntry
            } else {
                Text(companion.greeting)
                    .font(.system(size: 19, weight: .medium, design: .rounded)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(companion.activeEncounter.footer).font(.system(size: 11)).foregroundColor(secondaryInk)
                    Spacer()
                    Button(action: companion.openDiary) {
                        Image(systemName: "book.closed").font(.system(size: 13))
                            .frame(width: 30, height: 28).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).foregroundColor(accent)
                        .accessibilityLabel("翻开值班日记").help("翻开值班日记")
                }.padding(.top, 13)
            }
        }
        .padding(.horizontal, 19).padding(.top, 17).padding(.bottom, 17)
        .background {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(LinearGradient(colors: [paper, paper.mixForCat(with: palette.panel, amount: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(accent.opacity(0.20), lineWidth: 1))
    }

    private var diaryEntry: some View {
        let entry = CatCompanion.entries[companion.entryIndex]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.title).font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(String(format: "NOTE %02d", companion.entryIndex + 1))
                    .font(.system(size: 9, design: .monospaced)).tracking(1)
            }.foregroundColor(secondaryInk)
            Text(entry.text)
                .font(.system(size: 17, weight: .medium, design: .rounded)).lineSpacing(5)
                .frame(maxWidth: .infinity, minHeight: 57, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .id(companion.entryIndex)
                .transition(.opacity)
            HStack(alignment: .bottom, spacing: 8) {
                Text(entry.footer).font(.system(size: 10)).foregroundColor(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: companion.nextEntry) {
                    HStack(spacing: 4) {
                        Text("再翻一页")
                        Image(systemName: "arrow.right")
                    }.font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(accent.opacity(0.09), in: Capsule())
                }.buttonStyle(.plain).foregroundColor(accent).fixedSize()
                    .accessibilityLabel("再翻一页值班日记")
            }
            Button(action: companion.openBox) {
                HStack(spacing: 7) {
                    Image(systemName: "shippingbox")
                    Text("纸箱里好像有动静…")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }.font(.system(size: 10)).padding(10)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).foregroundColor(accent)
                .accessibilityLabel("看看日记旁的纸箱")
        }.animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: companion.entryIndex)
    }

    private var boxEntry: some View {
        let note = CatCompanion.boxNotes[companion.boxIndex]
        return VStack(alignment: .leading, spacing: 12) {
            Text(companion.boxOpen ? note.text : "里面是 Bug，\n还是一只摸鱼的猫？")
                .font(.system(size: 17, weight: .medium, design: .rounded)).lineSpacing(5)
                .frame(maxWidth: .infinity, minHeight: 57, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(companion.boxOpen ? note.footer : "先打开看看，再下结论。")
                .font(.system(size: 10)).foregroundColor(secondaryInk)
            HStack {
                Button(action: companion.openDiary) {
                    Label("回到日记", systemImage: "book.closed")
                        .font(.system(size: 10)).padding(.vertical, 7)
                }.buttonStyle(.plain).foregroundColor(secondaryInk)
                Spacer()
                Button(action: companion.toggleBox) {
                    Text(companion.boxOpen ? "让它藏好" : "打开看看")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(accent.opacity(0.11), in: Capsule())
                }.buttonStyle(.plain).foregroundColor(accent)
            }
        }
    }
}

private extension Color {
    func mixForCat(with other: Color, amount: Double) -> Color {
        Color(nsColor: NSColor(self).blended(withFraction: amount, of: NSColor(other)) ?? NSColor(self))
    }
}
