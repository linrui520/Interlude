import Foundation
import SwiftUI

@MainActor
enum LocalReset {
    static func reset(tasks: TaskStore, defaults: UserDefaults = .standard,
                      domainName: String = "com.interlude.desktop") throws {
        let previous = defaults.persistentDomain(forName: domainName)
        // Prevent an old standalone library from being silently reimported after a deliberate reset.
        defaults.setPersistentDomain(["interlude.personalMusic.didMigrateLegacyLibraries": true], forName: domainName)
        do {
            guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            try tasks.restoreBackupItems([])
        } catch {
            if let previous { defaults.setPersistentDomain(previous, forName: domainName) }
            else { defaults.removePersistentDomain(forName: domainName) }
            _ = defaults.synchronize()
            throw error
        }
    }
}

struct LocalResetSection: View {
    let tasks: TaskStore
    let onWillReset: () -> Void
    let onDidReset: () -> Void
    @State private var confirming = false
    @State private var errorMessage: String?

    var body: some View {
        Section(L("初始化", "Reset")) {
            Button(role: .destructive) { confirming = true } label: {
                Label(L("初始化所有数据与设置…", "Reset all data and settings…"), systemImage: "trash")
            }
            Text(L("清除间奏在当前 macOS 用户下的数据，并恢复首次使用状态。可先在「本地备份」导出需要保留的内容。",
                   "Clear Interlude’s data for this macOS user and return to first use. To keep a copy, export a local backup first."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert(L("初始化所有数据与设置？", "Reset all data and settings?"), isPresented: $confirming) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("清空并初始化", "Erase data and reset"), role: .destructive, action: performReset)
        } message: {
            Text(L("将清除全部待办、专注计时与历史、场景预设、目标、个人曲库路径与歌单、混音和其他设置，以及两份协议的同意记录与阅读进度。\n\n计时与播放将停止。原始音频文件、已导出的备份和报表会保留。清空后会回到首次使用协议，此操作无法撤销。",
                   "This clears all tasks, focus timers and history, presets, goals, personal library entries and playlists, sound mixes, other settings, reading progress, and both consent records.\n\nTimers and playback will stop. Original audio files, exported backups, and reports are kept. You will return to the first-use agreement. This action cannot be undone."))
        }
        .alert(L("初始化未完成", "Reset could not finish"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L("好", "OK")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func performReset() {
        onWillReset()
        do {
            try LocalReset.reset(tasks: tasks)
            onDidReset()
        } catch { errorMessage = error.localizedDescription }
    }
}
