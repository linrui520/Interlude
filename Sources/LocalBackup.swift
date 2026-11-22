import AppKit
import CoreFoundation
import SwiftUI
import UniformTypeIdentifiers

private enum BackupError: LocalizedError {
    case format, version, size, preferences
    var errorDescription: String? {
        switch self {
        case .format: return L("这份备份包含缺失、无效或无法识别的数据。", "The backup contains missing, invalid, or unrecognized data.")
        case .version: return L("此备份版本与当前间奏不兼容。", "This backup version is incompatible with this version of Interlude.")
        case .size: return L("请选取不超过 32 MB 的间奏备份文件。", "Choose an Interlude backup file of up to 32 MB.")
        case .preferences: return L("无法保存本机设置，请检查存储空间后重试。", "Your settings could not be saved. Check available storage and try again.")
        }
    }
}

@MainActor
enum LocalBackup {
    struct Archive {
        fileprivate let preferences: [String: Any]
        let tasks: [InterludeTask]
        let includesPersonalMusic: Bool
        let created: Date
    }

    private static let limit = 32 * 1024 * 1024
    private static let focusKey = "interlude.focus.v1"
    private static let extrasKey = "interlude.focusExtras.v1"
    private static let personal = "interlude.personalMusic."
    private static let ambient = "interlude.music."
    private static let settings = "interlude.settings."
    private static let signature = "com.interlude.local-backup"
    private static let manifestKeys: Set<String> = ["format", "version", "created", "tasks", "preferences", "includesPersonalMusic"]

    private enum ValueRule {
        case option([String]), level, toggle, identifier, focus, extras, tracks, lists, soundPresets, workflow, interfaceScale
    }

    private static let rules: [String: ValueRule] = {
        var all: [String: ValueRule] = [
            focusKey: .focus, extrasKey: .extras,
            "interlude.soundPresets.v1": .soundPresets, "interlude.focusWorkflow.v1": .workflow,
            settings + "highContrast": .toggle, settings + "interfaceScale": .interfaceScale,
            settings + "language": .option(AppLanguage.allCases.map(\.rawValue)),
            settings + "appearance": .option(AppAppearance.allCases.map(\.rawValue)),
            settings + "theme": .option(AppTheme.allCases.map(\.rawValue)),
            settings + "motion": .level, settings + "soundVolume": .level,
            settings + "phaseSound": .option(["none", "Glass", "Pop", "Ping", "Tink", "Submarine"]),
            settings + "musicFade": .toggle,
            settings + "shortcut": .option(["off", "commandOptionSpace", "commandShiftSpace"]),
            settings + "launchMode": .option(LaunchAnimationMode.allCases.map(\.rawValue)),
            settings + "launchOncePerDay": .toggle,
            ambient + "selection": .option(["stillroom", "daylight", "nocturne"]),
            personal + "selection": .identifier,
            personal + "library": .tracks, personal + "playlists": .lists
        ]
        for prefix in [ambient, personal] {
            all[prefix + "volume"] = .level
            all[prefix + "shuffle"] = .toggle
            all[prefix + "repeatOne"] = .toggle
        }
        for sound in ["rain", "ocean", "forest", "cafe"] { all["interlude.noise." + sound + ".volume"] = .level }
        return all
    }()

    // Only read portable keys, and only read personal metadata after local personal-music consent.
    static func export(tasks: TaskStore, focus: FocusModel, defaults: UserDefaults = .standard) throws -> Data {
        let includePersonal = defaults.integer(forKey: MusicWorkspaceModel.consentKey) == MusicWorkspaceModel.privacyVersion
        var values: [String: Any] = [:]
        for key in rules.keys where key != focusKey && (includePersonal || !key.hasPrefix(personal)) {
            guard let value = defaults.object(forKey: key) else { continue }
            // The old combined library could leave a personal UUID in the ambient selection slot.
            if key == ambient + "selection", let id = value as? String, UUID(uuidString: id) != nil { continue }
            if key == "interlude.soundPresets.v1", let data = value as? Data {
                values[key] = try SoundPresetStore.portableBackupData(data, includePersonalMusic: includePersonal)
            } else if key == "interlude.focusWorkflow.v1", let data = value as? Data {
                guard let sanitized = FocusWorkflowStore.sanitizedBackupData(data) else { throw BackupError.format }
                values[key] = sanitized
            } else { values[key] = value }
        }
        values[focusKey] = try focus.backupSnapshot()
        let manifest: [String: Any] = ["format": signature, "version": 2, "created": Date(),
            "tasks": try JSONEncoder().encode(tasks.itemsForBackup()), "preferences": values,
            "includesPersonalMusic": includePersonal]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0)
        _ = try decode(data)
        return data
    }

    static func read(_ url: URL) throws -> Archive {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) <= limit else { throw BackupError.size }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount: limit + 1) ?? Data())
    }

    static func decode(_ data: Data) throws -> Archive {
        guard data.count <= limit else { throw BackupError.size }
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(root.keys) == manifestKeys, root["format"] as? String == signature,
              let version = root["version"] as? NSNumber, isNumber(version),
              CFNumberIsFloatType(unsafeBitCast(version, to: CFNumber.self)) == false else { throw BackupError.format }
        guard version == 1 || version == 2 else { throw BackupError.version }
        guard let date = root["created"] as? Date, date.timeIntervalSinceReferenceDate.isFinite,
              let includePersonal = root["includesPersonalMusic"] as? NSNumber, !isNumber(includePersonal),
              let values = root["preferences"] as? [String: Any], values[focusKey] != nil,
              let taskData = root["tasks"] as? Data else { throw BackupError.format }
        for (key, value) in values {
            guard let rule = rules[key], includePersonal.boolValue || !key.hasPrefix(personal) else { throw BackupError.format }
            try validate(value, rule)
        }
        let tasks = try validatedTasks(taskData)
        try checkMusicReferences(values)
        return Archive(preferences: values, tasks: tasks, includesPersonalMusic: includePersonal.boolValue, created: date)
    }

    private static func isNumber(_ n: NSNumber) -> Bool { CFGetTypeID(n) != CFBooleanGetTypeID() }
    private static func validString(_ string: String, _ maxBytes: Int = 65536) -> Bool {
        !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && string.utf8.count <= maxBytes && !string.utf8.contains(0)
    }

    private static func validate(_ value: Any, _ rule: ValueRule) throws {
        switch rule {
        case .option(let allowed):
            guard let string = value as? String, allowed.contains(string) else { throw BackupError.format }
        case .identifier:
            guard let string = value as? String, validString(string, 256) else { throw BackupError.format }
        case .toggle:
            guard let n = value as? NSNumber, !isNumber(n) else { throw BackupError.format }
        case .level:
            guard let n = value as? NSNumber, isNumber(n), n.doubleValue.isFinite, (0...1).contains(n.doubleValue) else { throw BackupError.format }
        case .focus:
            guard let data = value as? Data else { throw BackupError.format }
            try FocusModel.validateBackup(data)
        case .extras:
            guard let data = value as? Data else { throw BackupError.format }
            try FocusExtrasStore.validateBackup(data)
        case .soundPresets:
            guard let data = value as? Data else { throw BackupError.format }
            guard SoundPresetStore.validateBackupData(data) else { throw BackupError.format }
        case .workflow:
            guard let data = value as? Data else { throw BackupError.format }
            guard FocusWorkflowStore.validateBackupData(data) else { throw BackupError.format }
        case .interfaceScale:
            guard let n = value as? NSNumber, isNumber(n), [1.0, 1.1, 1.2].contains(n.doubleValue) else { throw BackupError.format }
        case .tracks, .lists:
            guard value is Data else { throw BackupError.format }
        }
    }

    private static func rows(_ data: Data, limit: Int) throws -> [[String: Any]] {
        guard data.count <= Self.limit, let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              items.count <= limit else { throw BackupError.format }
        return items
    }

    private static func validatedTasks(_ data: Data) throws -> [InterludeTask] {
        try TaskStore.validateBackupItems(data)
    }

    private static func checkMusicReferences(_ values: [String: Any]) throws {
        var tracks = Set<String>()
        if let data = values[personal + "library"] as? Data {
            for item in try rows(data, limit: 50_000) {
                guard Set(item.keys).isSubset(of: ["id", "title", "detail", "path", "duration", "resource"]),
                      item["resource"] == nil || item["resource"] is NSNull,
                      let id = item["id"] as? String, validString(id, 256), tracks.insert(id).inserted,
                      let title = item["title"] as? String, validString(title),
                      let detail = item["detail"] as? String, detail.utf8.count <= 65536,
                      let path = item["path"] as? String, validString(path, 32768), path.hasPrefix("/"),
                      let duration = item["duration"] as? NSNumber, isNumber(duration), duration.doubleValue.isFinite,
                      duration.doubleValue > 0, duration.doubleValue <= 365 * 86400 else { throw BackupError.format }
            }
        }
        var lists = Set<String>()
        if let data = values[personal + "playlists"] as? Data {
            for item in try rows(data, limit: 10_000) {
                guard Set(item.keys) == ["id", "name", "trackIDs"],
                      let id = item["id"] as? String, validString(id, 256), lists.insert(id).inserted,
                      let name = item["name"] as? String, validString(name),
                      let members = item["trackIDs"] as? [String], members.count <= 50_000,
                      members.allSatisfy(tracks.contains), Set(members).count == members.count else { throw BackupError.format }
            }
        }
        // An older library can retain the last selection after removing its final track.
        // MusicModel falls back to the first available title when the selection is stale.
    }

    static func restore(_ archive: Archive, tasks: TaskStore, defaults: UserDefaults = .standard,
                        domainName: String = "com.interlude.desktop") throws {
        let previous = defaults.persistentDomain(forName: domainName) ?? [:]
        var restored = previous
        for key in rules.keys where archive.includesPersonalMusic || !key.hasPrefix(personal) {
            restored[key] = archive.preferences[key]
        }
        // Device-specific file selections are never imported or retained by restore.
        restored["interlude.focusWorkflow.files.v1"] = nil
        if let data = restored["interlude.focusWorkflow.v1"] as? Data {
            guard let sanitized = FocusWorkflowStore.sanitizedBackupData(data) else { throw BackupError.format }
            restored["interlude.focusWorkflow.v1"] = sanitized
        }
        if archive.includesPersonalMusic {
            // Explicitly replacing this library must not re-add removed songs from a legacy installation.
            restored[personal + "didMigrateLegacyLibraries"] = true
        }
        defaults.setPersistentDomain(restored, forName: domainName)
        do {
            guard defaults.synchronize() else { throw BackupError.preferences }
            // Atomic replacement is the last fallible operation. On failure the task file is intact.
            try tasks.restoreBackupItems(archive.tasks)
        } catch {
            defaults.setPersistentDomain(previous, forName: domainName)
            _ = defaults.synchronize()
            throw error
        }
    }
}

struct LocalBackupSection: View {
    let focus: FocusModel
    let tasks: TaskStore
    let onWillRestore: () -> Void
    let onDidRestore: () -> Void
    @State private var pending: LocalBackup.Archive?
    @State private var error: String?

    var body: some View {
        Section(L("本地备份", "Local backup")) {
            HStack {
                Button(L("导出备份…", "Export backup…"), action: save)
                Button(L("恢复备份…", "Restore backup…"), action: open)
            }
            Text(L("保存待办、专注、预设和设置。个人音乐已授权时，还包含曲目路径和歌单。备份不含音频与同意记录。",
                   "Save tasks, focus sessions, presets, and settings. With personal music enabled, track paths and playlists are included. Audio and consent records stay on this Mac."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert(L("覆盖当前数据？", "Replace current data?"), isPresented: Binding(get: { pending != nil },
                set: { if !$0 { pending = nil } }), presenting: pending) { archive in
            Button(L("取消", "Cancel"), role: .cancel) { pending = nil }
            Button(L("覆盖并恢复", "Replace and restore"), role: .destructive) {
                pending = nil
                onWillRestore()
                do {
                    try LocalBackup.restore(archive, tasks: tasks)
                    onDidRestore()
                } catch { self.error = error.localizedDescription }
            }
        } message: { archive in
            Text(L("备份含 \(archive.tasks.count) 项待办。继续将暂停计时和播放，用备份覆盖待办、专注记录与设置。",
                   "The backup contains \(archive.tasks.count) tasks. Restoring pauses playback and the timer, then replaces your tasks, focus records, and settings.")
                 + "\n" + (archive.includesPersonalMusic ?
                    L("个人曲库与歌单也将被替换。原音频文件及本机同意记录保持原样。", "Your personal library and playlists will also be replaced. Original audio files and this Mac’s consent records are preserved.") :
                    L("这份备份不含个人曲库。现有曲库与歌单将被保留。", "This backup omits personal music. Existing tracks and playlists will be preserved.")))
        }
        .alert(L("备份操作未完成", "Backup operation could not finish"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("好", "OK")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "Interlude-\(Date.now.formatted(.iso8601.year().month().day())).plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LocalBackup.export(tasks: tasks, focus: focus).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pending = try LocalBackup.read(url) }
        catch { self.error = error.localizedDescription }
    }
}
