import AppKit
import Carbon
import SwiftUI

@MainActor
final class GlobalShortcutController: ObservableObject {
    @Published private(set) var status: String?
    private var action: (() -> Void)?
    private var generation: UInt32 = 0
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x494E544C else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<GlobalShortcutController>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in controller.handle(identifier) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func configure(_ shortcut: String, action: @escaping () -> Void) {
        unregister()
        status = nil
        guard shortcut != "off" else { return }
        guard handler != nil else {
            status = L("无法注册快捷键，请重新打开间奏后重试。", "The shortcut handler could not start. Please reopen Interlude.")
            return
        }
        let modifiers = shortcut == "commandOptionSpace" ? UInt32(cmdKey | optionKey) : UInt32(cmdKey | shiftKey)
        let result = RegisterEventHotKey(UInt32(kVK_Space), modifiers,
                                        EventHotKeyID(signature: 0x494E544C, id: generation),
                                        GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            status = L("快捷键被其他应用占用，请换一个组合。", "This shortcut is unavailable. Please choose another combination.")
        } else {
            self.action = action
        }
    }

    func unregister() {
        generation &+= 1
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        action = nil
    }

    private func handle(_ identifier: EventHotKeyID) {
        guard hotKey != nil, identifier.signature == 0x494E544C, identifier.id == generation else { return }
        action?()
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct AppSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var shortcut: GlobalShortcutController
    let focus: FocusModel
    let tasks: TaskStore
    var music: MusicWorkspaceModel? = nil
    var onWillRestore: () -> Void = {}
    var onDidRestore: () -> Void = {}
    var onDidReset: () -> Void = {}

    var body: some View {
        Form {
            Section(L("语言与外观", "Language & appearance")) {
                Picker(L("语言", "Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("外观", "Appearance"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("主题色", "Accent theme"), selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("动画强度", "Animation intensity"))
                        Spacer()
                        Text(settings.motion < 0.01 ? L("关闭", "Off") : "\(Int(settings.motion * 100))%")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $settings.motion, in: 0...1, step: 0.1)
                        .accessibilityLabel(L("动画强度", "Animation intensity"))
                    Text(L("系统的“减少动态效果”也会被尊重。", "The macOS Reduce Motion setting is also respected."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("无障碍", "Accessibility")) {
                Picker(L("界面与文字大小", "Interface and text size"), selection: $settings.interfaceScale) {
                    Text("100%").tag(1.0)
                    Text("110%").tag(1.1)
                    Text("120%").tag(1.2)
                }
                Toggle(L("增强对比度", "Increase contrast"), isOn: $settings.highContrast)
                Text(L("也会遵循 macOS 的增强对比度和减少动态效果设置。放大后窗口最小尺寸会相应增加，避免裁切内容。", "macOS Increase Contrast and Reduce Motion are also respected. A larger interface increases the minimum window size to keep content visible."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("⌘1–5 切换页面；⌘⇧P 开始或暂停；⌘⇧R 重置计时与轮次。使用 Tab 在控件间移动；可在系统键盘设置中开启键盘导航。", "⌘1–5 switches pages; ⌘⇧P starts or pauses; ⌘⇧R resets the timer and cycle. Use Tab between controls; enable Keyboard Navigation in macOS keyboard settings when needed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let music { FocusWorkflowSettings(library: music) }
            Section(L("启动动画", "Launch animation")) {
                Picker(L("播放长度", "Length"), selection: $settings.launchMode) {
                    ForEach(LaunchAnimationMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("每天只播放一次", "Play only once per day"), isOn: $settings.launchOncePerDay)
                    .disabled(settings.launchMode == .off)
                Text(L("下次启动生效。可随时跳过；关闭动画或减少动态效果时直接进入。", "Applies on the next launch. Skip at any time; disabling motion or using Reduce Motion enters directly."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            LocalBackupSection(focus: focus, tasks: tasks, onWillRestore: onWillRestore, onDidRestore: onDidRestore)
            Section(L("提醒与声音", "Alerts & sound")) {
                Picker(L("阶段结束提示音", "Phase completion sound"), selection: $settings.phaseSound) {
                    Text(L("无", "None")).tag("none")
                    ForEach(["Glass", "Pop", "Ping", "Tink", "Submarine"], id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text(L("提示音音量", "Alert volume"))
                    Slider(value: $settings.soundVolume, in: 0...1)
                        .accessibilityLabel(L("提示音音量", "Alert volume"))
                        .accessibilityValue("\(Int(settings.soundVolume * 100))%")
                    Button(L("试听", "Preview")) { settings.playPhaseSound() }.disabled(settings.phaseSound == "none")
                }
                Toggle(L("音乐淡入淡出", "Fade music in and out"), isOn: $settings.musicFade)
            }
            Section(L("快捷操作", "Quick actions")) {
                Picker(L("全局开始 / 暂停专注", "Global focus toggle"), selection: $settings.shortcut) {
                    Text("⌘⇧Space").tag("commandShiftSpace")
                    Text("⌘⌥Space").tag("commandOptionSpace")
                    Text(L("关闭", "Off")).tag("off")
                }
                if let status = shortcut.status {
                    Text(status).font(.caption).foregroundStyle(.orange)
                }
                Text(L("快捷键在间奏运行时有效。关闭主窗口后，可从菜单栏继续操作。", "The shortcut works while Interlude is running. Use the menu bar after closing the main window."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("快捷指令", "Shortcuts")) {
                Text(L("在 macOS“快捷指令”中搜索“间奏”或 Interlude，可添加开始专注、暂停计时、添加待办、播放声音预设四种操作。声音预设名称需与音乐页保存的名称一致。", "Search for Interlude in macOS Shortcuts to start focus, pause the timer, add a task, or play a sound preset. Use the exact preset name saved on the Music page."))
                    .font(.callout)
                Text(L("首次运行前请打开间奏并接受协议。待恢复的计时需要先在应用中处理；快捷指令不会代替同意或恢复选择。", "Open Interlude and accept its agreement first. Resolve any interrupted timer in the app; shortcuts do not bypass consent or recovery decisions."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            LocalResetSection(tasks: tasks, onWillReset: onWillRestore, onDidReset: onDidReset)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(AppPalette.accent)
    }
}

struct MenuTimerLabel: View {
    @ObservedObject var focus: FocusModel
    var body: some View {
        Label(focus.remainingLabel, systemImage: focus.isRunning ? "timer" : "pause.circle")
            .monospacedDigit()
    }
}

struct MenuTimerView: View {
    @ObservedObject var focus: FocusModel
    let openWorkspace: () -> Void
    let showFloating: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(focus.modeLabel).font(.headline)
                Spacer()
                Text(L("第 \(focus.nextRound) 轮", "Round \(focus.nextRound)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(focus.remainingLabel).font(.system(size: 42, weight: .light, design: .rounded)).monospacedDigit()
            if let title = focus.selectedTaskTitle {
                Label(title, systemImage: "checklist").font(.caption).lineLimit(2)
            }
            if focus.hasRecovery {
                Button(L("处理上次中断的计时…", "Review interrupted timer…"), action: openWorkspace)
                    .font(.caption)
            }
            Button(action: focus.toggle) {
                Label(focus.isRunning ? L("暂停", "Pause") : L("开始 / 继续", "Start / resume"),
                      systemImage: focus.isRunning ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(AppPalette.accent).disabled(focus.hasRecovery)
            Divider()
            Button(L("打开间奏", "Open Interlude"), action: openWorkspace)
            Button(L("悬浮迷你播放器", "Floating mini player"), action: showFloating)
            Button(L("退出间奏", "Quit Interlude")) { NSApp.terminate(nil) }
        }
        .padding(20).frame(width: 280)
        .foregroundStyle(AppPalette.ink).background(AppPalette.paper)
    }
}

@MainActor
final class FloatingPlayerController {
    private var panel: NSPanel?

    func show(focus: FocusModel, music: MusicWorkspaceModel, settings: AppSettings) {
        if let panel { panel.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 160, y: 180, width: 370, height: 240),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = L("间奏迷你播放器", "Interlude mini player")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FloatingPlayerRoot(focus: focus, library: music, settings: settings))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() { panel?.close(); panel = nil }
}

private struct FloatingPlayerRoot: View {
    @ObservedObject var focus: FocusModel
    @ObservedObject var library: MusicWorkspaceModel
    @ObservedObject var settings: AppSettings
    var body: some View {
        FloatingPlayerView(focus: focus, music: library.activePlayer, settings: settings)
            .id(settings.visualIdentity)
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(\.locale, settings.locale)
    }
}

private struct FloatingPlayerView: View {
    @ObservedObject var focus: FocusModel
    @ObservedObject var music: MusicModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("INTERLUDE / MINI").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2)
                Spacer()
                Text(L("拖动窗口移动", "Drag to move")).font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(.leading, 44)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(focus.modeLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(focus.remainingLabel).font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                }
                Spacer()
                Button(action: focus.toggle) {
                    Image(systemName: focus.isRunning ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 31)).foregroundStyle(AppPalette.accent)
                }.buttonStyle(.plain).help(L("开始 / 暂停专注", "Start / pause focus"))
                    .accessibilityLabel(focus.isRunning ? L("暂停计时", "Pause timer") : L("开始计时", "Start timer"))
            }
            Divider()
            HStack(spacing: 13) {
                TimelineView(.animation(minimumInterval: 1/24, paused: !music.isPlaying || settings.reduceMotion)) { time in
                    ZStack {
                        Circle().fill(Color(white: 0.10))
                        ForEach(0..<5) { i in
                            Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.7).padding(CGFloat(i) * 3 + 4)
                        }
                        Circle().fill(AppPalette.accent).frame(width: 18, height: 18)
                        Capsule().fill(.white.opacity(0.8)).frame(width: 2, height: 7).offset(y: -5)
                    }
                    .rotationEffect(.degrees(music.isPlaying && !settings.reduceMotion ? time.date.timeIntervalSinceReferenceDate * 22 * settings.motion : 0))
                }
                .frame(width: 50, height: 50).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(music.currentTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 20) {
                        transport("backward.end.fill", L("上一首", "Previous"), music.previousTrack)
                        transport(music.isPlaying ? "pause.fill" : "play.fill", music.isPlaying ? L("暂停音乐", "Pause music") : L("播放音乐", "Play music"), music.togglePlayback)
                        transport("forward.end.fill", L("下一首", "Next"), music.nextTrack)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18).padding(.top, 10)
        .frame(width: 370, height: 240)
        .foregroundStyle(AppPalette.ink).background(AppPalette.paper)
    }

    private func transport(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
