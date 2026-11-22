import AppKit
import AppIntents
import SwiftUI

private enum WorkspacePage: Int, CaseIterable, Identifiable {
    case focus = 1, tasks, music, statistics, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .focus: return L("专注计时", "Focus")
        case .tasks: return L("待办清单", "Tasks")
        case .music: return L("音乐播放器", "Music")
        case .statistics: return L("专注统计", "Statistics")
        case .settings: return L("设置", "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .focus: return "timer"
        case .tasks: return "checklist"
        case .music: return "music.note.list"
        case .statistics: return "chart.bar.xaxis"
        case .settings: return "slider.horizontal.3"
        }
    }
}

private enum Studio {
    static var paper: Color { AppPalette.paper }
    static var side: Color { AppPalette.side }
    static var ink: Color { AppPalette.ink }
    static var muted: Color { AppPalette.muted }
    static var line: Color { AppPalette.line }
    static var orange: Color { AppPalette.accent }
}

@MainActor
private final class Workspace: ObservableObject {
    @Published var showRestoredNotice = false
    @Published private(set) var navigationDirection: Double = 1
    @Published var page: WorkspacePage = .focus {
        willSet {
            if newValue != page { navigationDirection = newValue.rawValue > page.rawValue ? 1 : -1 }
        }
    }
    let focus = FocusModel()
    let tasks = TaskStore()
    let music = MusicWorkspaceModel()
    let shortcut = GlobalShortcutController()
    let floating = FloatingPlayerController()
    let settings: AppSettings
    var onRestored: () -> Void = {}
    var onReset: () -> Void = {}

    init(settings: AppSettings) {
        self.settings = settings
        focus.onPhaseFinished = { [weak settings] in settings?.playPhaseSound() }
        focus.onFocusCompleted = { [weak music] in music?.focusDidFinish() }
        focus.onFocusStarted = { [weak music] in music?.focusDidStart() }
        applySettings()
    }

    func applySettings() {
        music.ambient.fadeEnabled = settings.musicFade
        music.personal.fadeEnabled = settings.musicFade
        shortcut.configure(settings.shortcut) { [weak focus] in focus?.toggle() }
    }

    func prepareForRestore() {
        settings.stopPhaseSound()
        focus.pauseForAgreement()
        music.stopAll()
        floating.close()
    }

    func showFloating() { floating.show(focus: focus, music: music, settings: settings) }
}

private struct InterludeMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width
            for stripe in 0..<5 {
                let offset = Double(stripe) * 0.054
                var p = Path()
                p.move(to: CGPoint(x: (0.12 + offset) * s, y: 0.66 * s))
                p.addCurve(to: CGPoint(x: (0.64 + offset) * s, y: 0.34 * s),
                           control1: CGPoint(x: (0.38 + offset) * s, y: 0.72 * s),
                           control2: CGPoint(x: (0.37 + offset) * s, y: 0.28 * s))
                ctx.stroke(p, with: .color(Studio.paper),
                           style: StrokeStyle(lineWidth: s * 0.030, lineCap: .round))
            }
        }
        .background(Studio.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct Sidebar: View {
    @ObservedObject var workspace: Workspace
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @Environment(\.motionAmount) private var motionAmount
    @State private var hover: WorkspacePage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                InterludeMark().frame(width: 43, height: 43)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("间奏", "Interlude")).font(.system(size: AppLanguage.current == .english ? 19 : 22, weight: .semibold)).tracking(AppLanguage.current == .english ? 0 : 2).lineLimit(1)
                    Text("INTERLUDE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.8)
                        .foregroundStyle(Studio.muted)
                }
            }
            .padding(.leading, 9)
            .padding(.bottom, 30)

            VStack(spacing: 7) {
                ForEach(WorkspacePage.allCases) { item in
                    Button {
                        workspace.page = item
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 21)
                            Text(item.title).font(.system(size: 14, weight: workspace.page == item ? .semibold : .regular))
                            Spacer(minLength: 2)
                            Text("⌘" + String(item.rawValue))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .opacity(workspace.page == item ? 0.72 : 0.55)
                        }
                        .padding(.horizontal, 13)
                        .frame(height: 43)
                        .foregroundStyle(workspace.page == item ? Studio.paper : Studio.ink)
                        .background {
                            if workspace.page == item {
                                RoundedRectangle(cornerRadius: 9).fill(Studio.ink)
                                    .matchedGeometryEffect(id: "selectedPage", in: selection)
                            } else if hover == item {
                                RoundedRectangle(cornerRadius: 9).fill(Studio.ink.opacity(0.045))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InterludeButtonStyle(scale: 0.985))
                    .accessibilityAddTraits(workspace.page == item ? .isSelected : [])
                    .onHover { over in
                        if over { hover = item } else if hover == item { hover = nil }
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.89), value: workspace.page)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hover)
            Button(action: workspace.showFloating) {
                Label(L("悬浮播放器", "Floating player"), systemImage: "pip")
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.top, 21)
            }.buttonStyle(InterludeButtonStyle()).foregroundStyle(Studio.muted)
            Spacer(minLength: 20)
            WorkspaceMiniPlayer(library: workspace.music) { workspace.page = .music }
        }
        .padding(.horizontal, 16)
        .padding(.top, 51)
        .padding(.bottom, 21)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Studio.side)
        .overlay(alignment: .trailing) { Rectangle().fill(Studio.line).frame(width: 1) }
    }
}

private struct WorkspaceMiniPlayer: View {
    @ObservedObject var library: MusicWorkspaceModel
    let openLibrary: () -> Void

    var body: some View {
        MiniPlayer(model: library.activePlayer, openLibrary: openLibrary)
    }
}

private struct MiniPlayer: View {
    @ObservedObject var model: MusicModel
    let openLibrary: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @Environment(\.motionAmount) private var motionAmount

    var body: some View {
        VStack(spacing: 14) {
            Rectangle().fill(Studio.line).frame(height: 1)
            HStack(spacing: 8) {
                Button(action: openLibrary) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(Studio.ink)
                            TimelineView(.animation(minimumInterval: 1 / 20, paused: !model.isPlaying || reduceMotion)) { timeline in
                                let t = timeline.date.timeIntervalSinceReferenceDate
                                HStack(alignment: .center, spacing: 2) {
                                    ForEach(0..<5) { i in
                                        let base = [6.0, 12.0, 18.0, 10.0, 5.0][i]
                                        Capsule().fill(Color(red: 1, green: 0.58, blue: 0.34))
                                            .frame(width: 2, height: base * (model.isPlaying && !reduceMotion ? 1 - 0.24 * motionAmount + 0.24 * motionAmount * sin(t * 5 + Double(i) * 1.8) : 1))
                                    }
                                }
                            }
                        }
                        .frame(width: 33, height: 33)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.isPlaying ? L("正在播放", "Playing") : L("音乐", "Music"))
                                .font(.system(size: 10)).foregroundStyle(Studio.muted)
                            Text(model.currentTitle).font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(InterludeButtonStyle()).help(L("打开音乐播放器", "Open music player"))
                Spacer(minLength: 0)
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InterludeButtonStyle())
                .accessibilityLabel(model.isPlaying ? L("暂停音乐", "Pause music") : L("播放音乐", "Play music"))
                .help(model.isPlaying ? L("暂停音乐", "Pause music") : L("播放音乐", "Play music"))
            }
        }
    }
}

private struct WorkspaceDate: View {
    private var dateFormat: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: AppLanguage.current == .english ? "en" : "zh_Hans")
        f.dateFormat = AppLanguage.current == .english ? "EEE, MMM d" : "M月d日  EEEE"
        return f
    }
    var body: some View {
        TimelineView(.everyMinute) { timeline in
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                Text(dateFormat.string(from: timeline.date))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Studio.muted)
        }
    }
}

private struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @Environment(\.motionAmount) private var motionAmount

    var body: some View {
        GeometryReader { geometry in
            workspaceContent
                .frame(width: geometry.size.width / settings.interfaceScale, height: geometry.size.height / settings.interfaceScale)
                .scaleEffect(settings.interfaceScale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 940 * settings.interfaceScale, minHeight: 620 * settings.interfaceScale)
        .id(contrast == .increased ? "contrast-increased" : "contrast-normal")
    }

    private var workspaceContent: some View {
        HStack(spacing: 0) {
            Sidebar(workspace: workspace)
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    ZStack(alignment: .leading) {
                        Text(workspace.page.title)
                            .font(.system(size: 32, weight: .semibold)).tracking(-0.8)
                            .accessibilityAddTraits(.isHeader)
                            .id(workspace.page)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4 * motionAmount)))
                    }
                    Spacer()
                    WorkspaceDate()
                }
                ZStack(alignment: .topLeading) {
                    ForEach([workspace.page]) { page in
                        pageContent(page)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(workspace.page == page)
                            .accessibilityHidden(workspace.page != page)
                            .transition(PageMotion.transition(direction: workspace.navigationDirection,
                                                              amount: motionAmount, reduced: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
            .padding(.horizontal, 30)
            .padding(.top, 49)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Studio.paper)
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Studio.ink)
        .tint(Studio.orange)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.92), value: workspace.page)
        .alert(L("备份已恢复", "Backup restored"), isPresented: $workspace.showRestoredNotice) {
            Button(L("好", "OK")) { workspace.showRestoredNotice = false }
        } message: {
            Text(L("待办、专注和设置已更新。计时保持暂停，音乐不会自动播放。", "Tasks, focus records, and settings are updated. The timer stays paused and music does not start automatically."))
        }
    }

    @ViewBuilder private func pageContent(_ page: WorkspacePage) -> some View {
        switch page {
        case .focus: FocusPage(model: workspace.focus, onApplyMusic: workspace.music.applySceneMusic, currentMusicID: { workspace.music.sceneMusicID })
        case .tasks: TaskWorkspaceView(workspace: workspace, focus: workspace.focus)
        case .music: MusicWorkspacePage(library: workspace.music)
        case .statistics: StatisticsPage(model: workspace.focus)
        case .settings: AppSettingsPage(settings: workspace.settings, shortcut: workspace.shortcut, focus: workspace.focus, tasks: workspace.tasks, music: workspace.music, onWillRestore: workspace.prepareForRestore, onDidRestore: workspace.onRestored, onDidReset: workspace.onReset)
        }
    }
}

private struct TaskWorkspaceView: View {
    let workspace: Workspace
    @ObservedObject var focus: FocusModel
    var body: some View {
        TasksPage(store: workspace.tasks, startFocus: { task in
            focus.startTask(task)
            workspace.page = .focus
        }, focusMinutes: { id in focus.focusMinutes(for: id) }, completedRounds: { id in focus.completedRounds(for: id) })
    }
}

private final class InterludeDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct InterludeApp: App {
    @NSApplicationDelegateAdaptor(InterludeDelegate.self) private var delegate
    @StateObject private var agreement = AppAgreementModel()
    @StateObject private var session = InterludeSession()
    @StateObject private var settings = AppSettings()
    @StateObject private var launch = LaunchPresentation()
    @State private var showingAgreement = false
    @Environment(\.openWindow) private var openWindow

    init() {
        let agreement = AppAgreementModel()
        let settings = AppSettings()
        let session = InterludeSession()
        _agreement = StateObject(wrappedValue: agreement)
        _settings = StateObject(wrappedValue: settings)
        _session = StateObject(wrappedValue: session)
        InterludeAutomation.shared.handler = { [weak agreement, weak settings, weak session] action in
            guard let agreement, let settings, let session, agreement.hasAccepted else {
                throw InterludeAutomationError(message: L("请先在间奏中阅读并接受当前使用协议。", "Read and accept the current agreement in Interlude first."))
            }
            session.unlock(using: agreement, settings: settings)
            InterludeAutomation.shared.showWorkspace?()
            return try session.performAutomation(action)
        }
        InterludeShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        Window(L("间奏", "Interlude"), id: "workspace") {
            LaunchStage(presentation: launch, settings: settings) {
                Group {
                    if agreement.hasAccepted, let workspace = session.workspace {
                        WorkspaceView(workspace: workspace)
                    } else if agreement.hasAccepted {
                        ProgressView().frame(minWidth: 940, minHeight: 620)
                    } else {
                        AppAgreementReader(model: agreement)
                    }
                }
                .id(settings.visualIdentity)
            }
            .environmentObject(settings)
            .environment(\.locale, settings.locale)
            .environment(\.motionAmount, settings.reduceMotion ? 0 : settings.motion)
            .preferredColorScheme(settings.appearance.colorScheme)
            .onAppear {
                InterludeAutomation.shared.showWorkspace = {
                    openWindow(id: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .onChange(of: agreement.hasAccepted, initial: true) { _, accepted in
                if accepted { session.unlock(using: agreement, settings: settings) } else { session.lock() }
            }
            .onChange(of: settings.shortcut) { _, _ in session.workspace?.applySettings() }
            .onChange(of: settings.musicFade) { _, _ in session.workspace?.applySettings() }
            .onChange(of: settings.language) { _, _ in session.workspace?.applySettings() }
            .sheet(isPresented: $showingAgreement) {
                AppAgreementReview(model: agreement, close: { showingAgreement = false }, revoke: {
                    session.lock()
                    showingAgreement = false
                    agreement.revoke()
                })
                .preferredColorScheme(settings.appearance.colorScheme)
                .environment(\.locale, settings.locale)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 750)
        .commands {
            CommandMenu(L("工作区", "Workspace")) {
                ForEach(WorkspacePage.allCases) { p in
                    Button(p.title) {
                        session.workspace?.page = p
                        openWindow(id: "workspace")
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(p.rawValue))), modifiers: .command)
                    .disabled(!agreement.hasAccepted)
                }
                Divider()
                Button(L("开始 / 暂停计时", "Start / pause timer")) { session.workspace?.focus.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!agreement.hasAccepted)
                Button(L("重置计时与轮次", "Reset timer and cycle")) { session.workspace?.focus.reset() }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!agreement.hasAccepted)
                Button(L("悬浮迷你播放器", "Floating mini player")) { session.workspace?.showFloating() }
                    .disabled(!agreement.hasAccepted)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("设置…", "Settings…")) {
                    session.workspace?.page = .settings
                    openWindow(id: "workspace")
                }.keyboardShortcut(",", modifiers: .command).disabled(!agreement.hasAccepted)
            }
            CommandGroup(replacing: .appInfo) {
                Button(L("关于间奏", "About Interlude")) {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: L("间奏", "Interlude"),
                        .applicationVersion: L("Pre-2 · 预发布", "Pre-2 · Prerelease"),
                        .version: "2.3 (16)",
                        .credits: NSAttributedString(string: "MIT License · GPT-6 Astra Ultra,lin_ruihgz")
                    ])
                }
            }
            CommandGroup(after: .appInfo) {
                Button(L("隐私政策与使用协议…", "Privacy Policy & Terms…")) {
                    openWindow(id: "workspace")
                    showingAgreement = true
                }.disabled(!agreement.hasAccepted)
            }
        }
        MenuBarExtra(isInserted: Binding(get: { agreement.hasAccepted && session.workspace != nil }, set: { _ in })) {
            if let workspace = session.workspace {
                MenuTimerView(focus: workspace.focus, openWorkspace: {
                    openWindow(id: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                }, showFloating: workspace.showFloating)
                .id(settings.visualIdentity)
                .preferredColorScheme(settings.appearance.colorScheme)
            }
        } label: {
            if let workspace = session.workspace { MenuTimerLabel(focus: workspace.focus) }
            else { Image(systemName: "timer") }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class InterludeSession: ObservableObject {
    @Published private(set) var workspace: Workspace?

    func unlock(using agreement: AppAgreementModel, settings: AppSettings) {
        guard agreement.hasAccepted, workspace == nil else { return }
        let fresh = Workspace(settings: settings)
        fresh.onRestored = { [weak self, weak settings, weak agreement] in
            guard let self, let settings, let agreement else { return }
            self.workspace?.shortcut.unregister()
            self.workspace = nil
            settings.reload()
            self.unlock(using: agreement, settings: settings)
            self.workspace?.page = .settings
            self.workspace?.showRestoredNotice = true
        }
        fresh.onReset = { [weak self, weak settings, weak agreement] in
            guard let self, let settings, let agreement else { return }
            self.workspace?.shortcut.unregister()
            self.workspace = nil
            agreement.revoke()
            settings.reload()
        }
        workspace = fresh
    }

    func performAutomation(_ action: InterludeAutomationAction) throws -> String {
        guard let workspace else { throw InterludeAutomationError(message: L("工作区尚未准备好，请重新打开间奏。", "The workspace is not ready. Reopen Interlude.")) }
        switch action {
        case .startFocus:
            workspace.page = .focus
            guard !workspace.focus.hasRecovery else { throw InterludeAutomationError(message: L("有一轮中断的计时，请先在间奏中选择恢复、补记或放弃。", "An interrupted timer needs your decision in Interlude: resume, record elapsed time, or discard.")) }
            workspace.focus.startFocus()
            return L("专注计时已开始。", "Focus is running.")
        case .pauseFocus:
            workspace.focus.pauseFocus()
            return L("计时已暂停。", "The timer is paused.")
        case .addTask(let title):
            guard workspace.tasks.add(title) else { throw InterludeAutomationError(message: workspace.tasks.storageError ?? L("请填写有效的待办名称。", "Enter a valid task title.")) }
            workspace.page = .tasks
            return L("待办已保存。", "Task saved.")
        case .playPreset(let name):
            workspace.page = .music
            guard workspace.music.playPreset(named: name) else { throw InterludeAutomationError(message: L("无法播放该预设。请核对预设名称、曲目是否可用，以及个人音乐是否已授权。", "The preset could not be played. Check its name, available tracks, and Personal Music consent in Interlude.")) }
            return L("声音预设已应用。", "Sound preset applied.")
        }
    }

    func lock() {
        workspace?.settings.stopPhaseSound()
        workspace?.shortcut.unregister()
        workspace?.floating.close()
        workspace?.focus.pauseForAgreement()
        workspace?.music.stopAll()
        workspace?.music.personal.setPersonalAccess(false)
        workspace = nil
    }
}
