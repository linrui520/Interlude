import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FocusWorkflowConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var presetID: String?
    var openFiles = false
    var fadeOnFinish = true
}

struct FocusWorkflowFile: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var bookmark: Data
}

@MainActor
final class FocusWorkflowStore: ObservableObject {
    static let storageKey = "interlude.focusWorkflow.v1"
    /// Device-specific authority: never include this key in a portable backup.
    static let filesKey = "interlude.focusWorkflow.files.v1"
    @Published private(set) var configuration = FocusWorkflowConfiguration()
    @Published private(set) var files: [FocusWorkflowFile] = []
    @Published var notice: String?
    private let settings: UserDefaults
    private var panel: NSOpenPanel?
    private var generation = 0
    private var fadeForCurrentFocus = false
    nonisolated private static let extensions = ["pdf", "txt", "md", "rtf", "doc", "docx", "odt", "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key", "pages", "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"]

    init(settings: UserDefaults = .standard) {
        self.settings = settings
        if let data = settings.data(forKey: Self.storageKey), Self.validateBackupData(data),
           let value = try? JSONDecoder().decode(FocusWorkflowConfiguration.self, from: data) { configuration = value }
        if let data = settings.data(forKey: Self.filesKey), data.count < 2_000_000,
           let entries = try? JSONDecoder().decode([FocusWorkflowFile].self, from: data), entries.count <= 20,
           Set(entries.map(\.id)).count == entries.count,
           entries.allSatisfy({ AudioSettingsValidation.identifier($0.id) && !$0.name.isEmpty && $0.name.count <= 255 && $0.bookmark.count <= 100_000 }) {
            files = entries
        }
    }

    nonisolated static func validateBackupData(_ data: Data) -> Bool {
        guard data.count <= 4096,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              AudioSettingsValidation.keys(raw, required: ["enabled", "openFiles", "fadeOnFinish"], optional: ["presetID"]),
              let value = try? JSONDecoder().decode(FocusWorkflowConfiguration.self, from: data),
              value.presetID.map(AudioSettingsValidation.identifier) ?? true else { return false }
        return true
    }

    /// Backups transfer preferences, never authority to start playback or open local files.
    nonisolated static func sanitizedBackupData(_ data: Data) -> Data? {
        guard validateBackupData(data), var value = try? JSONDecoder().decode(FocusWorkflowConfiguration.self, from: data) else { return nil }
        value.enabled = false
        value.openFiles = false
        return try? JSONEncoder().encode(value)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configuration) { settings.set(data, forKey: Self.storageKey) }
    }
    private func persistFiles() {
        if let data = try? JSONEncoder().encode(files) { settings.set(data, forKey: Self.filesKey) }
    }
    func setEnabled(_ enabled: Bool) {
        configuration.enabled = enabled
        if !enabled { fadeForCurrentFocus = false }
        persist()
    }
    func setPreset(_ id: String?) { configuration.presetID = id; persist() }
    func setOpenFiles(_ enabled: Bool) { configuration.openFiles = enabled; persist() }
    func setFadeOnFinish(_ enabled: Bool) { configuration.fadeOnFinish = enabled; persist() }
    func removeFile(_ id: String) { files.removeAll { $0.id == id }; persistFiles() }

    func chooseFiles() {
        guard panel == nil else { return }
        let picker = NSOpenPanel()
        picker.title = L("选择专注时打开的文档", "Choose documents to open for focus")
        picker.prompt = L("添加文档", "Add Documents")
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = Self.extensions.compactMap { UTType(filenameExtension: $0) }
        picker.allowsOtherFileTypes = false
        panel = picker
        let selectionGeneration = generation
        picker.begin { [weak self, weak picker] response in
            Task { @MainActor in
                guard let self, self.generation == selectionGeneration, let picker else { return }
                defer { self.panel = nil }
                guard response == .OK else { return }
                var skipped = 0
                for url in picker.urls {
                    guard self.files.count < 20, Self.isAllowedDocument(url),
                          let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { skipped += 1; continue }
                    let existingPaths = self.files.compactMap { entry -> String? in
                        var stale = false
                        return (try? URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI, .withoutMounting, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL.path
                    }
                    guard !existingPaths.contains(url.standardizedFileURL.path) else { continue }
                    self.files.append(FocusWorkflowFile(name: url.lastPathComponent, bookmark: bookmark))
                }
                self.persistFiles()
                if skipped > 0 { self.notice = L("部分文件未添加。仅支持文档和图片，最多 20 个。", "Some files were skipped. Choose documents or images, up to 20 files.") }
            }
        }
    }

    nonisolated static func isAllowedDocument(_ url: URL) -> Bool {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              !FileManager.default.isExecutableFile(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return true
    }

    /// This is called exclusively for a newly started focus interval, never init, resume or recovery.
    func focusDidStart(applyPreset: (String) -> Bool, openDocuments: (() -> Void)? = nil) {
        fadeForCurrentFocus = false
        guard configuration.enabled else { return }
        fadeForCurrentFocus = configuration.fadeOnFinish
        if let id = configuration.presetID { _ = applyPreset(id) }
        if configuration.openFiles {
            if let openDocuments { openDocuments() } else { openSelectedDocuments() }
        }
    }

    func focusDidFinish(fade: () -> Void) {
        let shouldFade = fadeForCurrentFocus && configuration.enabled && configuration.fadeOnFinish
        fadeForCurrentFocus = false
        if shouldFade { fade() }
    }

    func cancelPendingActions() {
        generation += 1
        panel?.cancel(nil)
        panel = nil
        fadeForCurrentFocus = false
    }

    private func openSelectedDocuments() {
        var failed: [String] = []
        for entry in files {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: entry.bookmark,
                                     options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale), !stale else {
                failed.append(entry.name); continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard Self.isAllowedDocument(url), NSWorkspace.shared.open(url) else { failed.append(entry.name); continue }
        }
        if !failed.isEmpty {
            notice = L("这些文档未能打开，请重新选择：", "These documents could not be opened. Select them again: ") + failed.joined(separator: ", ")
        }
    }
}

#if !INTERLUDE_MODEL_TESTS
struct FocusWorkflowSettings: View {
    @ObservedObject var library: MusicWorkspaceModel
    var body: some View { FocusWorkflowSettingsContent(store: library.workflow, presets: library.presets) }
}

private struct FocusWorkflowSettingsContent: View {
    @ObservedObject var store: FocusWorkflowStore
    @ObservedObject var presets: SoundPresetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle(L("启用一键专注流程", "Enable Focus Routine"), isOn: Binding(get: { store.configuration.enabled }, set: store.setEnabled))
            Text(L("每段新的专注开始时执行，包括休息后自动开始的下一轮。继续或恢复计时、启动应用及还原备份不会执行。", "Runs at the start of each new focus period, including automatic starts after breaks. Resuming or recovering a timer, launching the app and restoring a backup never run the routine."))
                .font(.caption).foregroundStyle(AppPalette.muted).fixedSize(horizontal: false, vertical: true)
            Picker(L("开始时的混音", "Mix at start"), selection: Binding(get: { store.configuration.presetID ?? "" }, set: { store.setPreset($0.isEmpty ? nil : $0) })) {
                Text(L("保持当前播放", "Keep current audio")).tag("")
                ForEach(presets.presets) { Text($0.name).tag($0.id) }
                if let id = store.configuration.presetID, !presets.presets.contains(where: { $0.id == id }) {
                    Text(L("预设已移除", "Preset unavailable")).tag(id)
                }
            }
            Text(L("在音乐页的“混音预设”中保存当前混音。个人音乐始终需要先同意隐私说明。", "Save a mix under Presets on the Music page. Personal music always requires privacy consent."))
                .font(.caption).foregroundStyle(AppPalette.muted).fixedSize(horizontal: false, vertical: true)
            Toggle(L("专注结束时淡出音乐和声景", "Fade music and soundscapes at focus end"), isOn: Binding(get: { store.configuration.fadeOnFinish }, set: store.setFadeOnFinish))
            Divider()
            Toggle(L("开始时打开我选择的文档", "Open my selected documents at start"), isOn: Binding(get: { store.configuration.openFiles }, set: store.setOpenFiles))
            Text(L("只打开下列文档或图片，不运行应用或脚本。文件授权仅保存在本机，备份不会包含它们。", "Only the documents and images listed below open; apps and scripts are excluded. File access stays on this Mac and is excluded from backups."))
                .font(.caption).foregroundStyle(AppPalette.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(store.files) { file in
                HStack {
                    Image(systemName: "doc").accessibilityHidden(true)
                    Text(file.name).lineLimit(1)
                    Spacer()
                    Button { store.removeFile(file.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel(L("移除文档：", "Remove document: ") + file.name)
                }.font(.caption)
            }
            Button(L("选择文档…", "Choose Documents…"), action: store.chooseFiles).disabled(store.files.count >= 20)
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(AppPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}
#endif
