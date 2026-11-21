import AppKit
import Combine
import SwiftUI

private enum FocusMode: String, CaseIterable, Codable {
    case focus, shortBreak, longBreak

    var name: String {
        switch self {
        case .focus: return L("专注", "Focus")
        case .shortBreak: return L("短休息", "Short break")
        case .longBreak: return L("长休息", "Long break")
        }
    }

    var icon: String {
        switch self {
        case .focus: return "scope"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak: return "sun.horizon"
        }
    }

    var standardMinutes: Int {
        switch self {
        case .focus: return 25
        case .shortBreak: return 5
        case .longBreak: return 15
        }
    }
}

struct FocusRecord: Codable {
    let end: Date
    let seconds: Int
    var taskID: UUID?
    var taskTitle: String?
    var isPartial: Bool?

    var completedRound: Bool { isPartial != true }
}

private struct FocusState: Codable {
    var mode = FocusMode.focus
    var durations: [String: Int] = [:]
    var remaining = 25 * 60
    var deadline: Date?
    var pausedInterval: TimeInterval?
    var pausedAt: Date?
    var completed: [FocusRecord] = []
    var finished = false
    var completedInCycle: Int?
    var selectedTaskID: UUID?
    var selectedTaskTitle: String?

    var nextRound: Int {
        min(3, max(0, completedInCycle ?? 0)) + 1
    }

    func minutes(for mode: FocusMode) -> Int {
        min(180, max(1, durations[mode.rawValue] ?? mode.standardMinutes))
    }
}

@MainActor
final class FocusModel: ObservableObject {
    @Published private var state: FocusState
    let extras: FocusExtrasStore
    var onPhaseFinished: (() -> Void)?
    var onFocusCompleted: (() -> Void)?
    private let defaults: UserDefaults
    private let key = "interlude.focus.v1"
    private var clock: AnyCancellable?
    private var dayChange: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        extras = FocusExtrasStore(defaults: defaults)
        state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(FocusState.self, from: $0) } ?? FocusState()
        if state.completedInCycle == nil {
            state.completedInCycle = state.completed.count % 4
            persist()
        }
        if state.deadline != nil {
            tick(sound: false)
            if state.deadline != nil { runClock() }
        }
        dayChange = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isRunning: Bool { state.deadline != nil }
    func pauseForAgreement() {
        guard isRunning else { return }
        let now = Date()
        tick(at: now, sound: false)
        guard let end = state.deadline else { return }
        state.pausedInterval = max(0, end.timeIntervalSince(now))
        state.pausedAt = now
        state.deadline = nil
        clock = nil
        persist()
    }
    var remainingLabel: String { String(format: "%02d:%02d", state.remaining / 60, state.remaining % 60) }
    fileprivate var mode: FocusMode { state.mode }
    var nextRound: Int { state.nextRound }
    fileprivate var finished: Bool { state.finished }
    fileprivate var isMidSession: Bool { isRunning || state.pausedInterval != nil || (!finished && state.remaining < minutes(mode) * 60) }
    var remainingFraction: Double {
        min(1, max(0, (state.pausedInterval ?? Double(state.remaining)) / Double(minutes(mode) * 60)))
    }
    var canReset: Bool { finished || isMidSession || nextRound != 1 || mode != .focus }
    fileprivate func minutes(_ mode: FocusMode) -> Int { state.minutes(for: mode) }
    var isBreak: Bool { mode != .focus }
    var modeLabel: String { mode.name }
    var sceneDurations: [Int] { [minutes(.focus), minutes(.shortBreak), minutes(.longBreak)] }

    func applyScene(_ scene: FocusPreset) {
        guard scene.valid else { return }
        finishInterruptedFocus()
        state.durations = [FocusMode.focus.rawValue: scene.focusMinutes,
                           FocusMode.shortBreak.rawValue: scene.shortMinutes,
                           FocusMode.longBreak.rawValue: scene.longMinutes]
        state.mode = .focus
        resetPhase()
    }

    func backupSnapshot() throws -> Data {
        let now = Date()
        var copy = state
        if let end = copy.deadline, end <= now {
            copy = Self.advance(copy, completedAt: end, nextStart: now)
        }
        if let deadline = copy.deadline {
            let interval = min(Double(copy.minutes(for: copy.mode) * 60), max(0, deadline.timeIntervalSince(now)))
            copy.pausedInterval = interval
            copy.pausedAt = now
            copy.remaining = Int(ceil(interval))
            copy.deadline = nil
        }
        let data = try JSONEncoder().encode(copy)
        try Self.validateBackup(data)
        return data
    }

    static func validateBackup(_ data: Data) throws {
        let allowed = ["mode", "durations", "remaining", "deadline", "pausedInterval", "pausedAt",
                       "completed", "finished", "completedInCycle", "selectedTaskID", "selectedTaskTitle"]
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys).isSubset(of: allowed),
              let records = raw["completed"] as? [[String: Any]], records.count <= 200_000,
              records.allSatisfy({ Set($0.keys).isSubset(of: ["end", "seconds", "taskID", "taskTitle", "isPartial"]) })
        else { throw FocusExtrasError.invalidBackup }
        let candidate = try JSONDecoder().decode(FocusState.self, from: data)
        let maximum = candidate.minutes(for: candidate.mode) * 60
        let validDurations = candidate.durations.allSatisfy {
            FocusMode(rawValue: $0.key) != nil && (1...180).contains($0.value)
        }
        guard candidate.deadline == nil, validDurations,
              (0...maximum).contains(candidate.remaining),
              candidate.finished ? candidate.remaining == 0 : candidate.remaining > 0,
              (0...3).contains(candidate.completedInCycle ?? 0),
              candidate.pausedInterval.map({ $0.isFinite && $0 > 0 && $0 <= Double(maximum) && Int(ceil($0)) == candidate.remaining }) ?? true,
              candidate.pausedAt.map(FocusExtrasStore.validDate) ?? true,
              candidate.pausedAt == nil || candidate.pausedInterval != nil,
              (candidate.selectedTaskTitle?.utf8.count ?? 0) <= 65_536,
              candidate.completed.allSatisfy({
                  (1...10800).contains($0.seconds) && FocusExtrasStore.validDate($0.end)
                      && ($0.taskTitle?.utf8.count ?? 0) <= 65_536
              })
        else { throw FocusExtrasError.invalidBackup }
    }
    var selectedTaskID: UUID? { state.selectedTaskID }
    var selectedTaskTitle: String? { state.selectedTaskTitle }
    var todayCount: Int { today.filter(\.completedRound).count }
    var todayMinutes: Int { today.reduce(0) { $0 + $1.seconds } / 60 }
    private var today: [FocusRecord] { statisticsRecords.filter { Calendar.current.isDateInToday($0.end) } }

    private func activeRecord(at now: Date) -> FocusRecord? {
        guard mode == .focus, !finished else { return nil }
        let duration = minutes(.focus) * 60
        let timeLeft = state.deadline?.timeIntervalSince(now) ?? state.pausedInterval ?? Double(state.remaining)
        let elapsed = min(duration, max(0, duration - Int(ceil(timeLeft))))
        guard elapsed > 0 else { return nil }
        return FocusRecord(end: state.pausedAt ?? now, seconds: elapsed, taskID: selectedTaskID,
                           taskTitle: selectedTaskTitle, isPartial: true)
    }

    var statisticsRecords: [FocusRecord] {
        if let active = activeRecord(at: Date()) { return state.completed + [active] }
        return state.completed
    }

    func focusMinutes(for taskID: UUID) -> Int {
        statisticsRecords.lazy.filter { $0.taskID == taskID }.reduce(0) { $0 + $1.seconds } / 60
    }

    // Credit the outgoing focus segment once, including elapsed time from before a pause.
    private func finishInterruptedFocus() {
        let now = Date()
        tick(at: now, sound: false)
        if let partial = activeRecord(at: now) { state.completed.append(partial) }
    }

    func startTask(_ task: InterludeTask) {
        tick(sound: false)
        if mode == .focus, selectedTaskID == task.id {
            state.selectedTaskTitle = task.title
            persist()
            if !isRunning { toggle() }
            return
        }
        finishInterruptedFocus()
        state.mode = .focus
        state.selectedTaskID = task.id
        state.selectedTaskTitle = task.title
        resetPhase()
        toggle()
    }

    func clearTask() {
        guard selectedTaskID != nil else { return }
        finishInterruptedFocus()
        state.selectedTaskID = nil
        state.selectedTaskTitle = nil
        if mode == .focus { resetPhase() } else { persist() }
    }

    func toggle() {
        let now = Date()
        if isRunning {
            tick(at: now)
            guard let end = state.deadline else { return }
            state.pausedInterval = end.timeIntervalSince(now)
            state.pausedAt = now
            state.deadline = nil
            clock = nil
        } else {
            if finished { resetPhase() }
            state.deadline = now.addingTimeInterval(state.pausedInterval ?? Double(state.remaining))
            state.pausedInterval = nil
            state.pausedAt = nil
            runClock()
        }
        persist()
    }

    func reset() {
        finishInterruptedFocus()
        state.completedInCycle = 0
        state.mode = .focus
        resetPhase()
    }

    private func resetPhase() {
        clock = nil
        state.deadline = nil
        state.pausedInterval = nil
        state.pausedAt = nil
        state.finished = false
        state.remaining = minutes(mode) * 60
        persist()
    }

    fileprivate func select(_ next: FocusMode) {
        finishInterruptedFocus()
        state.mode = next
        resetPhase()
    }

    fileprivate func setMinutes(_ value: Int) {
        finishInterruptedFocus()
        state.durations[mode.rawValue] = min(180, max(1, value))
        resetPhase()
    }

    private func runClock() {
        clock = Timer.publish(every: 0.25, tolerance: 0.08, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.tick() }
    }

    private func tick(at now: Date = Date(), sound: Bool = true) {
        guard let end = state.deadline else { return }
        let remaining = max(0, Int(ceil(end.timeIntervalSince(now))))
        if remaining > 0 {
            if state.remaining != remaining { state.remaining = remaining }
            return
        }

        let completedFocus = state.mode == .focus
        state = Self.advance(state, completedAt: end, nextStart: now)
        persist()
        if completedFocus { onFocusCompleted?() }
        if sound { onPhaseFinished?() }
    }

    private static func advance(_ state: FocusState, completedAt end: Date, nextStart now: Date) -> FocusState {
        var next = state
        if state.mode == .focus {
            next.completed.append(FocusRecord(end: end, seconds: state.minutes(for: .focus) * 60,
                                              taskID: state.selectedTaskID, taskTitle: state.selectedTaskTitle))
            let completedRound = next.nextRound
            next.completedInCycle = completedRound % 4
            next.mode = completedRound == 4 ? .longBreak : .shortBreak
        } else {
            next.mode = .focus
        }

        // A missed deadline completes the actual session once. Give the newly
        // started phase its full duration, even when restoring after a long sleep.
        next.remaining = next.minutes(for: next.mode) * 60
        next.deadline = now.addingTimeInterval(Double(next.remaining))
        next.pausedInterval = nil
        next.pausedAt = nil
        next.finished = false
        return next
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}

private let focusCream = Color(red: 0.99, green: 0.97, blue: 0.91)

struct FocusPage: View {
    @ObservedObject var model: FocusModel
    var onApplyMusic: (String) -> Void = { _ in }
    var currentMusicID: () -> String? = { nil }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @Environment(\.motionAmount) private var motionAmount
    @State private var editing = false
    @State private var draft = ""
    @State private var pending: FocusMode?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    FocusSceneBar(model: model, extras: model.extras,
                                  onApplyMusic: onApplyMusic, currentMusicID: currentMusicID)
                        .padding(.bottom, 12)
                    hero
                        .frame(height: min(350, max(220, geo.size.height - 257)))
                    DailyGoalView(model: model, extras: model.extras).padding(.top, 12)
                    BreakReminderView(extras: model.extras, isBreak: model.isBreak, round: model.nextRound)
                    HStack(spacing: 10) {
                        Text(L("时段", "Session")).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button {
                            draft = String(model.minutes(model.mode))
                            editing = true
                        } label: {
                            Label(L("调整时长", "Edit duration"), systemImage: "slider.horizontal.3")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(InterludeButtonStyle())
                        .foregroundStyle(AppPalette.ink.opacity(0.7))
                        .popover(isPresented: $editing, arrowEdge: .bottom) { durationEditor }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                    HStack(spacing: 9) {
                        ForEach(FocusMode.allCases, id: \.self) { mode in
                            modeButton(mode)
                        }
                    }
                    if let taskTitle = model.selectedTaskTitle {
                        HStack(spacing: 7) {
                            Image(systemName: "checklist")
                            Text(taskTitle).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Button(L("结束关联", "Unlink task")) { model.clearTask() }
                                .buttonStyle(InterludeButtonStyle()).foregroundStyle(AppPalette.accent)
                                .help(L("结束任务关联并保存已专注的时间", "Unlink the task and save its focus time"))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.top, 12)
                    }
                    HStack(spacing: 7) {
                        Image(systemName: "clock").font(.system(size: 11))
                        Text(L("今日专注", "Today"))
                        Text(L("\(model.todayCount) 轮", model.todayCount == 1 ? "1 round" : "\(model.todayCount) rounds")).foregroundStyle(AppPalette.ink)
                        Text("·")
                        Text(L("\(model.todayMinutes) 分钟", "\(model.todayMinutes) min")).foregroundStyle(AppPalette.ink)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.ink.opacity(0.60))
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                }
            }
            .scrollIndicators(.automatic)
        }
        .foregroundStyle(AppPalette.ink)
        .onChange(of: model.mode) { _, _ in editing = false }
        .alert(L("切换时段？", "Switch session?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { mode in
            Button(L("切换到", "Switch to ") + mode.name) { model.select(mode) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: { _ in Text(L("切换后将重新计时。", "Switching starts a fresh timer.")) }
    }

    private var hero: some View {
        GeometryReader { g in
            let wide = g.size.width >= 620
            HStack(spacing: 0) {
                FocusSun(running: model.isRunning, mode: model.mode, remaining: model.remainingFraction)
                    .frame(width: g.size.width * 0.49)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(AppPalette.accent).frame(width: 7, height: 7)
                        Text(status).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(focusCream.opacity(0.84))
                        Text("·").foregroundStyle(focusCream.opacity(0.40))
                        Text(model.mode == .focus ? L("第 \(model.nextRound) / 4 轮", "Round \(model.nextRound) / 4") : L("接下来第 \(model.nextRound) 轮", "Next: round \(model.nextRound)"))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(focusCream.opacity(0.67))
                    }
                    .help(L("专注结束后自动休息，每完成四轮专注进入长休息。休息结束后自动开始下一轮专注。", "Breaks and focus sessions start automatically. Every fourth focus session is followed by a long break."))
                    Text(model.remainingLabel)
                        .font(.system(size: wide ? 78 : 61, weight: .light, design: .default))
                        .monospacedDigit()
                        .tracking(-3.5)
                        .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22 * motionAmount), value: model.remainingLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(focusCream)
                        .padding(.top, 4)
                        .padding(.bottom, 17)
                        .accessibilityLabel(L("剩余 ", "Time left: ") + model.remainingLabel)
                    HStack(spacing: 10) {
                        Button {
                            model.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text(buttonText).font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, wide ? 19 : 13)
                            .frame(height: 37)
                            .background(focusCream, in: Capsule())
                            .foregroundStyle(Color(red: 0.12, green: 0.125, blue: 0.115))
                        }.buttonStyle(FocusPressStyle())
                        Button { model.reset() } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 37, height: 37)
                                .overlay(Circle().stroke(focusCream.opacity(0.30), lineWidth: 1))
                        }
                        .buttonStyle(FocusPressStyle())
                        .foregroundStyle(focusCream)
                        .disabled(!model.canReset)
                        .opacity(model.canReset ? 1 : 0.52)
                        .help(L("重置计时与轮次", "Reset timer and cycle")).accessibilityLabel(L("重置计时与轮次", "Reset timer and cycle"))
                    }
                }
                .padding(.trailing, 16)
                .padding(.leading, wide ? 15 : 5)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LinearGradient(colors: [Color(red: 0.15, green: 0.14, blue: 0.13), Color(red: 0.105, green: 0.11, blue: 0.105)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var status: String {
        if model.finished { return L("本轮已完成", "Session complete") }
        if model.isRunning { return L(model.mode.name + "中", model.mode == .focus ? "Focusing" : "On a break") }
        if model.isMidSession { return L("已暂停", "Paused") }
        return L(model.mode.name + "时段", model.mode.name)
    }

    private var buttonText: String {
        if model.isRunning { return L("暂停计时", "Pause") }
        if model.finished { return L("再来一轮", "Start again") }
        if model.isMidSession { return L("继续计时", "Resume") }
        return L("开始" + model.mode.name, "Start " + model.mode.name.lowercased())
    }

    private func modeButton(_ mode: FocusMode) -> some View {
        let selected = model.mode == mode
        return Button {
            guard mode != model.mode else { return }
            if model.isMidSession { pending = mode } else { model.select(mode) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? AppPalette.accent : AppPalette.ink.opacity(0.6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.name).font(.system(size: 13, weight: .semibold))
                    Text(L("\(model.minutes(mode)) 分钟", "\(model.minutes(mode)) min")).font(.system(size: 11)).foregroundStyle(AppPalette.ink.opacity(0.64))
                }
                Spacer(minLength: 0)
                if selected {
                    Circle().fill(AppPalette.accent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(selected ? AppPalette.accent.opacity(0.065) : AppPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? AppPalette.accent.opacity(0.72) : AppPalette.ink.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(FocusPressStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22 * motionAmount), value: selected)
    }

    private var durationEditor: some View {
        let value = Int(draft.trimmingCharacters(in: .whitespaces))
        let valid = value.map { (1...180).contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            Text(L(model.mode.name + "时长", model.mode.name + " duration")).font(.headline)
            HStack {
                TextField("1–180", text: $draft)
                    .frame(width: 72)
                    .onSubmit { if valid, let value { model.setMinutes(value); editing = false } }
                Text(L("分钟", "min"))
            }
            Text(model.isMidSession ? L("应用后将重新计时。", "Applying this restarts the timer.") : L("可设为 1 至 180 分钟。", "Choose 1–180 minutes.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("取消", "Cancel")) { editing = false }
                Spacer()
                Button(L("应用", "Apply")) { if let value { model.setMinutes(value); editing = false } }
                    .disabled(!valid)
            }
        }
        .padding(16).frame(width: 210)
    }
}

private struct FocusPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @Environment(\.motionAmount) private var motionAmount
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 1 - 0.03 * motionAmount : 1)
            .opacity(configuration.isPressed ? 0.83 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14 * motionAmount), value: configuration.isPressed)
    }
}

private struct FocusSun: View {
    let running: Bool
    let mode: FocusMode
    let remaining: Double
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @Environment(\.motionAmount) private var motionAmount
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            orbit
            strands
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("本轮剩余进度", "Session time remaining"))
        .accessibilityValue(Text(remaining.formatted(.percent.precision(.fractionLength(0)))))
    }

    private var orbit: some View {
        GeometryReader { g in
            let diameter = min(g.size.width * 0.86, g.size.height * 0.89)
            ZStack {
                Circle().stroke(focusCream.opacity(0.13), lineWidth: 1)
                Circle().trim(from: 0, to: remaining)
                    .stroke(Color(red: 0.95, green: 0.64, blue: 0.39).opacity(0.54), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(Color(red: 1.0, green: 0.76, blue: 0.48))
                    .frame(width: 4, height: 4)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(360 * remaining))
            }
            .frame(width: diameter, height: diameter)
            .position(x: g.size.width * 0.52, y: g.size.height / 2)
            .animation(reduceMotion ? nil : .linear(duration: 0.36 * motionAmount), value: remaining)
        }
    }

    private var strands: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running || reduceMotion || scenePhase != .active)) { timeline in
            let phase = !reduceMotion && running ? timeline.date.timeIntervalSinceReferenceDate * 0.36 : 0
            FocusThreads(mode: mode)
                .equatable()
                .drawingGroup()
                .scaleEffect(1 + sin(phase) * 0.023 * motionAmount)
                .rotationEffect(.degrees(sin(phase * 0.6) * 4 * motionAmount))
        }
    }
}

// Each meridian follows the varying cross-section of the same torus. Painting
// distant meridians first leaves a luminous edge on the near side of the ring.
private struct FocusThreads: View, Equatable {
    let mode: FocusMode

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width * 0.41, size.height * 0.46)
            guard unit > 1 else { return }
            let center = CGPoint(x: size.width * 0.52, y: size.height * 0.5)
            let glow = Path(ellipseIn: CGRect(x: center.x - unit * 1.25, y: center.y - unit * 1.25, width: unit * 2.5, height: unit * 2.5))
            context.fill(glow, with: .radialGradient(Gradient(colors: [
                Color(red: 0.98, green: 0.40, blue: 0.11).opacity(0.12), .clear
            ]), center: center, startRadius: 0, endRadius: unit * 1.25))
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: unit, y: unit)
            context.rotate(by: .degrees(-30))
            let tau = 2 * Double.pi
            let tilt = mode == .longBreak ? 0.7 : (mode == .shortBreak ? 0.82 : 0.94)
            for depth in 0..<82 {
                for side in [-1.0, 1.0] {
                    let azimuth = -Double.pi / 2 + (Double(depth) + 0.4) * Double.pi / 82
                    let a = side > 0 ? azimuth : Double.pi - azimuth
                    let s = sin(a)
                    let c = cos(a)
                    let radius = 0.657 + 0.067 * sin(2 * a + 0.85)
                    let tube = 0.302 + 0.055 * cos(2 * a - 0.2)
                    var path = Path()
                    for i in 0...52 {
                        let b = Double(i) / 52 * tau
                        let r = radius + tube * cos(b)
                        let x = r * c
                        let elevation = tube * sin(b) + 0.13 * sin(2 * a - 0.6)
                        let y = r * s * cos(tilt) - elevation * sin(tilt)
                        let pt = CGPoint(x: x, y: y)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    path.closeSubpath()
                    let light = (s + 1) / 2
                    let color = Color(red: 0.94 + light * 0.06, green: 0.32 + light * 0.45, blue: 0.10 + light * 0.24)
                    context.stroke(path, with: .color(color.opacity(0.52 + 0.44 * light)), lineWidth: 0.006)
                }
            }
        }
    }
}
