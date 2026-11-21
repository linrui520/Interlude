import SwiftUI

enum FocusExtrasError: LocalizedError {
    case invalidBackup, invalidName, duplicateName, tooManyScenes
    var errorDescription: String? {
        switch self {
        case .invalidBackup: return L("专注设置或计时记录无效。", "Invalid focus settings or timer records.")
        case .invalidName: return L("请填写 1 至 60 个字符的名称。", "Enter a name between 1 and 60 characters.")
        case .tooManyScenes: return L("自定义场景已满，请先删除一个场景。", "The custom scene library is full. Remove a scene first.")
        case .duplicateName: return L("已有同名场景，请换个名称。", "That scene name is already in use.")
        }
    }
}

struct FocusPreset: Codable, Identifiable {
    var id: String
    var name: String
    var focusMinutes: Int
    var shortMinutes: Int
    var longMinutes: Int
    var theme: String
    var musicID: String

    var valid: Bool {
        !id.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60
            && [focusMinutes, shortMinutes, longMinutes].allSatisfy { (1...180).contains($0) }
            && AppTheme(rawValue: theme) != nil && ["none", "stillroom", "daylight", "nocturne"].contains(musicID)
    }

    static var builtIns: [FocusPreset] {
        [
            FocusPreset(id:"study", name:L("学习", "Study"), focusMinutes:25, shortMinutes:5, longMinutes:15, theme:"ocean", musicID:"stillroom"),
            FocusPreset(id:"writing", name:L("写作", "Writing"), focusMinutes:45, shortMinutes:8, longMinutes:20, theme:"ember", musicID:"nocturne"),
            FocusPreset(id:"work", name:L("工作", "Work"), focusMinutes:50, shortMinutes:10, longMinutes:20, theme:"forest", musicID:"daylight")
        ]
    }

    var durationLabel: String {
        L("专注 \(focusMinutes) 分钟 · 短休息 \(shortMinutes) 分钟 · 长休息 \(longMinutes) 分钟",
          "\(focusMinutes) min focus · \(shortMinutes) min short break · \(longMinutes) min long break")
    }
}

@MainActor
final class FocusExtrasStore: ObservableObject {
    private struct Preferences: Codable {
        var dailyGoal = 60
        var showBreakTips = true
        var customScenes = [FocusPreset]()
        var lastCelebration: Date?
    }
    private static let maxScenes = 2_000
    static let key = "interlude.focusExtras.v1"
    private let defaults: UserDefaults
    @Published private var preferences: Preferences

    init(defaults: UserDefaults) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.key).flatMap { try? Self.decoded($0) } ?? Preferences()
    }

    var dailyGoal: Int { preferences.dailyGoal }
    var showBreakTips: Bool { preferences.showBreakTips }
    var customScenes: [FocusPreset] { preferences.customScenes }

    nonisolated static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (-2_208_988_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }

    private static func decoded(_ data: Data) throws -> Preferences {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys).isSubset(of: ["dailyGoal", "showBreakTips", "customScenes", "lastCelebration"]),
              let scenes = raw["customScenes"] as? [[String: Any]], scenes.count <= maxScenes,
              scenes.allSatisfy({ Set($0.keys).isSubset(of: ["id", "name", "focusMinutes", "shortMinutes", "longMinutes", "theme", "musicID"]) })
        else { throw FocusExtrasError.invalidBackup }
        let prefs = try JSONDecoder().decode(Preferences.self, from: data)
        let ids = prefs.customScenes.map(\.id)
        guard (1...1440).contains(prefs.dailyGoal), prefs.customScenes.allSatisfy(\.valid),
              ids.allSatisfy({ UUID(uuidString: $0) != nil }), Set(ids).count == ids.count,
              prefs.lastCelebration.map(validDate) ?? true
        else { throw FocusExtrasError.invalidBackup }
        return prefs
    }

    static func validateBackup(_ data: Data) throws { _ = try decoded(data) }

    func setGoal(_ minutes: Int) {
        guard (1...1440).contains(minutes) else { return }
        preferences.dailyGoal = minutes
        persist()
    }

    func setBreakTips(_ enabled: Bool) {
        preferences.showBreakTips = enabled
        persist()
    }

    func saveScene(_ name: String, durations: [Int], theme: AppTheme, musicID: String?) throws {
        guard customScenes.count < Self.maxScenes else { throw FocusExtrasError.tooManyScenes }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { throw FocusExtrasError.invalidName }
        let allNames = (FocusPreset.builtIns + customScenes).map(\.name)
        guard !allNames.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw FocusExtrasError.duplicateName
        }
        guard durations.count == 3 else { throw FocusExtrasError.invalidBackup }
        let preset = FocusPreset(id: UUID().uuidString, name: trimmed, focusMinutes: durations[0], shortMinutes: durations[1],
                                 longMinutes: durations[2], theme: theme.rawValue, musicID: musicID ?? "none")
        guard preset.valid else { throw FocusExtrasError.invalidBackup }
        preferences.customScenes.append(preset)
        persist()
    }

    func deleteScene(_ id: String) {
        preferences.customScenes.removeAll { $0.id == id }
        persist()
    }

    func claimGoalAchievement(minutes: Int, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard minutes >= dailyGoal else { return false }
        if let previous = preferences.lastCelebration, calendar.isDate(previous, inSameDayAs: now) { return false }
        preferences.lastCelebration = now
        persist()
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.key) }
    }
}

struct FocusSceneBar: View {
    @ObservedObject var model: FocusModel
    @ObservedObject var extras: FocusExtrasStore
    let onApplyMusic: (String) -> Void
    let currentMusicID: () -> String?
    @EnvironmentObject private var settings: AppSettings
    @State private var saving = false
    @State private var name = ""
    @State private var error = ""

    private func apply(_ preset: FocusPreset) {
        model.applyScene(preset)
        onApplyMusic(preset.musicID)
        if let theme = AppTheme(rawValue: preset.theme) { settings.theme = theme }
    }

    private func save() {
        do {
            try extras.saveScene(name, durations: model.sceneDurations, theme: settings.theme, musicID: currentMusicID())
            saving = false
        } catch { self.error = error.localizedDescription }
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(L("场景", "Scenes"), systemImage: "square.grid.2x2")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppPalette.muted)
            ForEach(FocusPreset.builtIns) { preset in
                Button(preset.name) { apply(preset) }
                    .buttonStyle(.bordered)
                    .help(preset.durationLabel)
            }
            Spacer(minLength: 4)
            Menu {
                if !extras.customScenes.isEmpty {
                    ForEach(extras.customScenes) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                    Divider()
                }
                Button(L("保存当前场景…", "Save current scene…")) {
                    name = ""
                    error = ""
                    saving = true
                }
                if !extras.customScenes.isEmpty {
                    Menu(L("删除场景", "Delete scene")) {
                        ForEach(extras.customScenes) { preset in
                            Button(preset.name, role:.destructive) { extras.deleteScene(preset.id) }
                        }
                    }
                }
            } label: { Label(L("自定义场景", "Custom scenes"), systemImage:"slider.horizontal.3") }
            .fixedSize()
            .popover(isPresented: $saving, arrowEdge:.bottom) {
                VStack(alignment:.leading, spacing:12) {
                    Text(L("保存当前场景", "Save current scene")).font(.headline)
                    TextField(L("场景名称", "Scene name"), text:$name).onSubmit(save)
                    Text(L("保存三种时长、主题色和当前环境音乐。", "Saves all three durations, the accent theme, and the current ambient track."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button(L("取消", "Cancel")) { saving = false }
                        Spacer()
                        Button(L("保存", "Save"), action: save)
                            .disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                }.frame(width:254).padding(16)
            }
        }
    }
}

struct BreakReminderView: View {
    @ObservedObject var extras: FocusExtrasStore
    let isBreak: Bool
    let round: Int

    var body: some View {
        if isBreak && extras.showBreakTips {
            let tip: (String, String) = switch round % 3 {
            case 0: ("drop", L("喝几口水，放松片刻。", "Take a few sips of water."))
            case 1: ("figure.cooldown", L("起身轻轻伸展肩背。", "Stand up and gently stretch your shoulders."))
            default: ("eye", L("望向远处，让眼睛休息片刻。", "Look into the distance and rest your eyes."))
            }
            HStack {
                Label(tip.1, systemImage:tip.0).foregroundStyle(AppPalette.ink)
                Spacer()
                Button(L("关闭提示", "Turn off tips")) { extras.setBreakTips(false) }
                    .buttonStyle(.plain).foregroundStyle(AppPalette.muted)
            }
            .font(.system(size:12))
            .padding(10).background(AppPalette.accent.opacity(0.10), in:RoundedRectangle(cornerRadius:8))
            .padding(.top,10)
        }
    }
}

struct DailyGoalView: View {
    @ObservedObject var model: FocusModel
    @ObservedObject var extras: FocusExtrasStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.motionAmount) private var motion
    @State private var editing = false
    @State private var draft = ""
    @State private var celebrating = false
    @State private var draftTips = true
    private struct GoalStatus: Equatable { let day: Date; let reached: Bool }
    private var isReached: Bool { model.todayMinutes >= extras.dailyGoal }
    private var reduced: Bool { systemReduceMotion || motion <= 0 }

    var body: some View {
        VStack(alignment:.leading, spacing:8) {
            HStack(spacing:7) {
                Image(systemName: isReached ? "checkmark.seal.fill" : "target")
                    .foregroundStyle(AppPalette.accent)
                    .scaleEffect(celebrating && !reduced ? 1 + 0.18 * motion : 1)
                Text(isReached ? L("已达成每日目标", "Daily goal reached") : L("每日目标", "Daily goal"))
                    .font(.system(size:13,weight:.semibold))
                Text(L("\(model.todayMinutes) / \(extras.dailyGoal) 分钟", "\(model.todayMinutes) / \(extras.dailyGoal) min"))
                    .font(.system(size:12).monospacedDigit()).foregroundStyle(AppPalette.muted)
                Spacer()
                Button {
                    draft = String(extras.dailyGoal)
                    draftTips = extras.showBreakTips
                    editing = true
                } label: { Image(systemName:"slider.horizontal.3").frame(width:26,height:24) }
                .buttonStyle(InterludeButtonStyle())
                .help(L("设置每日目标和休息提示", "Set your daily goal and break tips"))
                .accessibilityLabel(L("设置每日目标和休息提示", "Set your daily goal and break tips"))
                .popover(isPresented:$editing, arrowEdge:.bottom) { editor }
            }
            ProgressView(value: min(1, Double(model.todayMinutes) / Double(extras.dailyGoal)))
                .tint(AppPalette.accent).accessibilityLabel(L("每日目标进度", "Daily goal progress"))
        }
        .padding(.horizontal,12).padding(.vertical,9)
        .background(AppPalette.card, in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).stroke(celebrating ? AppPalette.accent : AppPalette.line))
        .animation(reduced ? nil : .spring(response:0.30, dampingFraction:0.75), value:celebrating)
        .onChange(of: GoalStatus(day: Calendar.current.startOfDay(for: Date()), reached: isReached), initial:true) { _, status in
            if status.reached && extras.claimGoalAchievement(minutes:model.todayMinutes) { celebrating = true }
        }
        .task(id:celebrating) {
            guard celebrating else { return }
            try? await Task.sleep(for:.seconds(1.4))
            if !Task.isCancelled { celebrating = false }
        }
    }

    private func applyGoal(_ minutes: Int) {
        extras.setGoal(minutes)
        extras.setBreakTips(draftTips)
        editing = false
    }

    private var editor: some View {
        let minutes = Int(draft.trimmingCharacters(in:.whitespacesAndNewlines))
        let valid = minutes.map { (1...1440).contains($0) } ?? false
        return VStack(alignment:.leading, spacing:12) {
            Text(L("每日专注目标", "Daily focus goal")).font(.headline)
            HStack {
                TextField("1–1440", text:$draft).frame(width:75)
                    .onSubmit { if valid, let minutes { applyGoal(minutes) } }
                Text(L("分钟", "minutes"))
            }
            Text(L("可设为 1 至 1440 分钟。", "Choose 1–1,440 minutes."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("显示休息提示", "Show break tips"), isOn:$draftTips)
            HStack {
                Button(L("取消", "Cancel")) { editing = false }
                Spacer()
                Button(L("应用", "Apply")) {
                    if valid, let minutes { applyGoal(minutes) }
                }.disabled(!valid)
            }
        }.padding(16).frame(width:235)
    }
}
