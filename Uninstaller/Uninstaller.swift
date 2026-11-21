import AppKit
import SwiftUI

private struct RemovalResult: Sendable {
    let succeeded: Bool
    let cancelled: Bool
    let message: String
}

private func runAuthorizedRemoval(_ shell: String) -> RemovalResult {
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let script = "do shell script \"" + escaped + "\" with administrator privileges"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let output = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = output
    do {
        try process.run()
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return RemovalResult(succeeded: process.terminationStatus == 0,
                             cancelled: message.contains("(-128)"), message: message)
    } catch {
        return RemovalResult(succeeded: false, cancelled: false, message: error.localizedDescription)
    }
}

@MainActor
private final class UninstallerDelegate: NSObject, NSApplicationDelegate {
    static var isBusy = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isBusy ? .terminateCancel : .terminateNow
    }
}

@MainActor
private final class UninstallModel: ObservableObject {
    @Published var removeComponents = true
    @Published var removePersonalPlayer = true
    @Published var removePersonalData = false
    @Published var removeUninstaller = false
    @Published var busy = false {
        didSet {
            UninstallerDelegate.isBusy = busy
            for window in NSApp.windows {
                window.standardWindowButton(.closeButton)?.isEnabled = !busy
            }
        }
    }
    @Published var completed = false
    @Published var message: String?

    var personalDataDescription: String {
        let mainData = UL("间奏主程序的待办、专注记录、音乐库和设置", "Interlude tasks, focus history, music library and preferences")
        return removePersonalPlayer ? mainData + UL("，以及个人音乐播放器的音乐库和设置。", ", plus the legacy player’s library and preferences.") : mainData + UL("。", ".")
    }

    var confirmationText: String {
        let applications = removePersonalPlayer ? UL("间奏及旧版独立播放器", "Interlude and the legacy Personal Music player") : UL("间奏", "Interlude")
        var lines = [UL("将从“应用程序”永久移除", "The following will be permanently removed from Applications: ") + applications + UL("。", ".")]
        if removeComponents { lines.append(UL("同时移除原创音乐、源码工程和文档。源码中的修改也会被删除。", "The ambient tracks, source project and documents will also be removed, including edits made in the installed source folder.")) }
        if removePersonalData { lines.append(UL("当前用户将清除以下数据。\n", "Remove the following data for the current user:\n") + personalDataDescription) }
        if removeUninstaller { lines.append(UL("同时移除卸载程序。", "The uninstaller will also be removed.")) }
        lines.append(UL("卸载前将退出所选应用，请先保存正在编辑的事项。", "Save any drafts first. Selected applications will quit before removal."))
        lines.append(UL("继续后，macOS 将请求管理员授权。", "Continuing requests administrator authorization from macOS."))
        return lines.joined(separator: "\n\n")
    }

    func uninstall() {
        guard !busy else { return }
        busy = true
        message = nil
        let removeData = removePersonalData
        let removeUtility = removeUninstaller
        var identifiers = ["com.interlude.desktop"]
        if removePersonalPlayer { identifiers.append("com.interlude.personal-music") }
        let plan = UninstallPlan(removeComponents: removeComponents, removePersonalPlayer: removePersonalPlayer,
                                 removeUninstaller: false)
        Task {
            let running = identifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            for application in running { application.terminate() }
            for _ in 0..<30 {
                if running.allSatisfy({ $0.isTerminated }) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard running.allSatisfy({ $0.isTerminated }) else {
                let names = running.filter { !$0.isTerminated }.compactMap(\.localizedName).joined(separator: UL("、", ", "))
                message = UL("请先退出所选应用，然后重试。", "Quit the selected applications and try again.") + (names.isEmpty ? "" : " " + names)
                busy = false
                return
            }
            let command = plan.privilegedShell()
            let result = await Task.detached { runAuthorizedRemoval(command) }.value
            if result.cancelled {
                message = UL("已取消管理员授权，可重新选择卸载内容。", "Authorization was cancelled. You can revise your choices.")
            } else if !result.succeeded {
                message = UL("卸载未能全部完成。请检查提示后重试。\n", "Some items could not be removed. Review the details and try again.\n") + result.message
            } else {
                do {
                    if removeData { try removeCurrentUserData(identifiers: identifiers) }
                    if removeUtility {
                        let finalPlan = UninstallPlan(removeComponents: false, removePersonalPlayer: false,
                                                      removeUninstaller: true)
                        let finalCommand = finalPlan.privilegedShell()
                        let finalResult = await Task.detached { runAuthorizedRemoval(finalCommand) }.value
                        guard finalResult.succeeded else {
                            message = finalResult.cancelled
                                ? UL("主程序已卸载。移除卸载程序的授权已取消，可以重新尝试。", "Interlude was removed. Authorization to remove the uninstaller was cancelled. You can try again.")
                                : UL("主程序已卸载，卸载程序尚未移除，可以重试。\n", "Interlude was removed. The uninstaller remains. You can try again.\n") + finalResult.message
                            busy = false
                            return
                        }
                    }
                    completed = true
                } catch {
                    message = UL("程序卸载已完成，个人数据清理未完成。可以重试清理。\n", "The application was removed. Personal data cleanup is incomplete and can be retried.\n") + error.localizedDescription
                }
            }
            busy = false
        }
    }

    private func removeCurrentUserData(identifiers: [String]) throws {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Interlude", isDirectory: true)
        if fileManager.fileExists(atPath: support.path) {
            let attributes = try fileManager.attributesOfItem(atPath: support.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw NSError(domain: "InterludeUninstaller", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: UL("无法确认待办文件夹的位置，请检查 ", "Could not verify the task folder. Check ") + support.path])
            }
            let taskFile = support.appendingPathComponent("tasks.json")
            if fileManager.fileExists(atPath: taskFile.path) { try fileManager.removeItem(at: taskFile) }
        }
        for identifier in identifiers { try removeSettings(for: identifier) }
    }

    private func removeSettings(for bundleID: String) throws {
        let identifier = bundleID as CFString
        if let keys = CFPreferencesCopyKeyList(identifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) {
            CFPreferencesSetMultiple(nil, keys, identifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(identifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw NSError(domain: "InterludeUninstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: UL("无法清理偏好设置（", "Could not clear preferences (") + bundleID + UL("），请检查当前用户的资源库权限。", "). Check permissions for this user’s Library.")])
        }
        let fileManager = FileManager.default
        let savedState = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/" + bundleID + ".savedState", isDirectory: true)
        if fileManager.fileExists(atPath: savedState.path) { try fileManager.removeItem(at: savedState) }
    }
}

private struct UninstallerView: View {
    @StateObject private var model = UninstallModel()
    @State private var confirming = false
    private let ink = Color(red: 0.12, green: 0.125, blue: 0.115)
    private let accent = Color(red: 0.86, green: 0.30, blue: 0.16)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: model.completed ? "checkmark.circle" : "shippingbox")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(accent)
                    .frame(width: 64, height: 64)
                    .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.completed ? UL("卸载已完成", "Uninstall complete") : UL("卸载间奏", "Uninstall Interlude"))
                        .font(.system(size: 28, weight: .semibold))
                    Text(model.completed ? UL("所选内容已移除。", "The selected items have been removed.") : UL("选择需要移除的内容。", "Choose what to remove."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.completed {
                Text(model.removePersonalData ? UL("已清除", "Removed: ") + model.personalDataDescription : UL("已保留当前用户的待办、专注记录和音乐库设置。", "Tasks, focus history and music preferences were kept for this user."))
                    .font(.system(size: 14))
                if !model.removeUninstaller {
                    Text(UL("卸载程序可供后续清理使用。", "The uninstaller is available for future cleanup.")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack { Spacer(); Button(UL("完成", "Done")) { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction) }
            } else {
                VStack(alignment: .leading, spacing: 17) {
                    Label(UL("间奏主程序", "Interlude application"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                    Text("/Applications/间奏.app").font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.top, -10).padding(.leading, 25)
                    Divider()
                    Toggle(UL("移除「间奏个人音乐」独立播放器", "Remove the legacy Personal Music app"), isOn: $model.removePersonalPlayer)
                    Toggle(UL("移除附加组件", "Remove optional components"), isOn: $model.removeComponents)
                    Text(UL("原创音乐、源码工程和文档。请先备份源码中的修改。", "Ambient tracks, source project and documentation. Save any source edits first."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, -10)
                    Toggle(UL("清除当前用户的个人数据", "Clear this user’s personal data"), isOn: $model.removePersonalData)
                    Text(model.personalDataDescription)
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, -10)
                    Toggle(UL("同时移除卸载程序", "Remove the uninstaller too"), isOn: $model.removeUninstaller)
                }
                .toggleStyle(.checkbox)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.60), in: RoundedRectangle(cornerRadius: 13))
                .disabled(model.busy)
                Text(UL("卸载后，导入的原始音乐文件仍保存在原位。", "Your imported audio files will stay in their original locations."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let message = model.message {
                    ScrollView { Text(message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 70)
                        .foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                HStack {
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Text(UL("正在卸载…", "Uninstalling…")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(UL("关闭", "Close")) { NSApp.terminate(nil) }.disabled(model.busy)
                    Button(UL("卸载…", "Uninstall…")) { confirming = true }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(model.busy)
                }
            }
        }
        .padding(30)
        .frame(width: 570, height: 615)
        .background(Color(red: 0.965, green: 0.961, blue: 0.941))
        .foregroundStyle(ink)
        .preferredColorScheme(.light)
        .alert(UL("确认卸载间奏？", "Uninstall Interlude?"), isPresented: $confirming) {
            Button(UL("取消", "Cancel"), role: .cancel) {}
            Button(UL("确认卸载", "Uninstall"), role: .destructive) { model.uninstall() }
        } message: { Text(model.confirmationText) }
        .interactiveDismissDisabled(model.busy)
    }
}

@main
struct UninstallerApp: App {
    @NSApplicationDelegateAdaptor(UninstallerDelegate.self) private var delegate
    var body: some Scene {
        Window(UL("卸载间奏", "Uninstall Interlude"), id: "uninstaller") { UninstallerView() }
            .windowResizability(.contentSize)
    }
}
