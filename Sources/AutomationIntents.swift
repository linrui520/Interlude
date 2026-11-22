import AppIntents
import AppKit

// Every entry point shares the live workspace and its consent/recovery checks.
// No independent stores are constructed by Shortcuts, so there is no stale writer.
enum InterludeAutomationAction {
    case startFocus, pauseFocus, addTask(String), playPreset(String)
}
struct InterludeAutomationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
@MainActor
final class InterludeAutomation {
    static let shared = InterludeAutomation()
    var showWorkspace: (() -> Void)?
    var handler: ((InterludeAutomationAction) throws -> String)?
    func run(_ action: InterludeAutomationAction) throws -> String {
        guard let handler else {
            throw InterludeAutomationError(message: L("请先打开间奏，完成首次使用设置后再运行快捷指令。", "Open Interlude and finish its first-use setup before running this shortcut."))
        }
        return try handler(action)
    }
}

struct StartInterludeFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Start focus in Interlude"
    static var description = IntentDescription("Start or resume focus using your optional focus workflow. An already running focus session is left running.")
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try InterludeAutomation.shared.run(.startFocus)))
    }
}
struct PauseInterludeFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause the Interlude timer"
    static var description = IntentDescription("Pause the active timer without resetting its elapsed time.")
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try InterludeAutomation.shared.run(.pauseFocus)))
    }
}
struct AddInterludeTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add an Interlude task"
    static var description = IntentDescription("Save a new task to your local Interlude task list.")
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Task title") var taskTitle: String
    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$taskTitle) to Interlude") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try InterludeAutomation.shared.run(.addTask(taskTitle))))
    }
}
struct PlayInterludePresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Play an Interlude sound preset"
    static var description = IntentDescription("Play a saved music and soundscape preset by its exact name. Personal Music still requires consent in Interlude.")
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Preset name") var presetName: String
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$presetName) in Interlude") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try InterludeAutomation.shared.run(.playPreset(presetName))))
    }
}
struct InterludeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartInterludeFocusIntent(), phrases: ["Start focus in \(.applicationName)"], shortTitle: "Start focus", systemImageName: "timer")
        AppShortcut(intent: PauseInterludeFocusIntent(), phrases: ["Pause the timer in \(.applicationName)"], shortTitle: "Pause timer", systemImageName: "pause.circle")
        AppShortcut(intent: AddInterludeTaskIntent(), phrases: ["Add a task in \(.applicationName)"], shortTitle: "Add task", systemImageName: "checklist")
        AppShortcut(intent: PlayInterludePresetIntent(), phrases: ["Play a sound preset in \(.applicationName)"], shortTitle: "Play sound preset", systemImageName: "waveform")
    }
}
