import Foundation
import SwiftUI

/// Portable references only: personal music files remain in the consent-gated library.
struct SoundPreset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var musicSource: String
    var trackID: String?
    var playlistID: String?
    var playMusic: Bool
    var ambientVolume: Double
    var personalVolume: Double
    var soundscapes: [String: SoundscapeSetting]
}

struct SoundscapeSetting: Codable, Equatable, Sendable {
    var enabled: Bool
    var volume: Double
}

/// Reject unknown fields, overlong values, duplicate identities and non-finite levels before restore.
enum AudioSettingsValidation {
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
        }
    }
    static func title(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 80 &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func unit(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
    static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) -> Bool {
        required.isSubset(of: Set(object.keys)) && Set(object.keys).isSubset(of: required.union(optional))
    }
}

@MainActor
final class SoundPresetStore: ObservableObject {
    static let storageKey = "interlude.soundPresets.v1"
    @Published private(set) var presets: [SoundPreset] = []
    private let settings: UserDefaults

    init(settings: UserDefaults = .standard) {
        self.settings = settings
        if let data = settings.data(forKey: Self.storageKey), Self.validateBackupData(data),
           let values = try? JSONDecoder().decode([SoundPreset].self, from: data) { presets = values }
    }

    nonisolated static func validateBackupData(_ data: Data) -> Bool {
        guard data.count <= 256_000,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let values = try? JSONDecoder().decode([SoundPreset].self, from: data), values.count <= 100,
              raw.count == values.count, Set(values.map(\.id)).count == values.count,
              Set(values.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }).count == values.count else { return false }
        let kinds: Set<String> = ["rain", "ocean", "forest", "cafe"]
        for (object, value) in zip(raw, values) {
            guard AudioSettingsValidation.keys(object, required: ["id", "name", "musicSource", "playMusic", "ambientVolume", "personalVolume", "soundscapes"], optional: ["trackID", "playlistID"]),
                  AudioSettingsValidation.identifier(value.id), AudioSettingsValidation.title(value.name),
                  ["ambient", "personal"].contains(value.musicSource),
                  value.trackID.map(AudioSettingsValidation.identifier) ?? true,
                  value.playlistID.map(AudioSettingsValidation.identifier) ?? true,
                  value.musicSource == "personal" || value.playlistID == nil,
                  AudioSettingsValidation.unit(value.ambientVolume), AudioSettingsValidation.unit(value.personalVolume),
                  Set(value.soundscapes.keys) == kinds,
                  let rawSounds = object["soundscapes"] as? [String: [String: Any]] else { return false }
            for (kind, setting) in value.soundscapes {
                guard AudioSettingsValidation.unit(setting.volume), let rawSound = rawSounds[kind],
                      AudioSettingsValidation.keys(rawSound, required: ["enabled", "volume"]) else { return false }
            }
        }
        return true
    }

    enum BackupError: Error { case invalidData }

    nonisolated static func portableBackupData(_ data: Data, includePersonalMusic: Bool) throws -> Data {
        guard validateBackupData(data) else { throw BackupError.invalidData }
        let values = try JSONDecoder().decode([SoundPreset].self, from: data)
        return try JSONEncoder().encode(values.filter { includePersonalMusic || $0.musicSource != "personal" })
    }

    @discardableResult func save(_ preset: SoundPreset) -> Bool {
        guard presets.count < 100 || presets.contains(where: { $0.id == preset.id }) else { return false }
        var next = presets
        if let index = next.firstIndex(where: { $0.id == preset.id }) { next[index] = preset }
        else { next.append(preset) }
        guard let data = try? JSONEncoder().encode(next), Self.validateBackupData(data) else { return false }
        presets = next
        settings.set(data, forKey: Self.storageKey)
        return true
    }

    @discardableResult func rename(_ id: String, to name: String) -> Bool {
        guard var preset = presets.first(where: { $0.id == id }) else { return false }
        preset.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return save(preset)
    }

    func delete(_ id: String) {
        presets.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(presets) { settings.set(data, forKey: Self.storageKey) }
    }
}

#if !INTERLUDE_MODEL_TESTS
struct SoundPresetsButton: View {
    @ObservedObject var library: MusicWorkspaceModel
    @ObservedObject var store: SoundPresetStore
    @State private var showing = false
    @State private var editing = false
    @State private var name = ""
    @State private var editingID: String?
    @State private var validationError = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label(L("混音预设", "Presets"), systemImage: "square.stack")
        }
        .font(.system(size: 11, weight: .medium)).buttonStyle(InterludeButtonStyle())
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("我的混音预设", "Saved Mixes")).font(.headline)
                Text(L("保存当前曲目、歌单、音乐开关、音量和四种声景。点按播放才会应用。", "Save the current track, playlist, music on/off, volumes and four soundscapes. A mix plays only when you apply it."))
                    .font(.caption).foregroundStyle(AppPalette.muted).fixedSize(horizontal: false, vertical: true)
                if store.presets.isEmpty {
                    Text(L("还没有预设。先调好喜欢的混音，再保存。", "Set up a mix you like, then save it here."))
                        .font(.caption).foregroundStyle(AppPalette.muted)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(store.presets) { preset in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(preset.name).lineLimit(1)
                                        Text(preset.musicSource == "personal" ? L("个人音乐与声景", "Personal music & soundscapes") : L("环境音乐与声景", "Ambient music & soundscapes"))
                                            .font(.caption2).foregroundStyle(AppPalette.muted)
                                    }
                                    Spacer()
                                    Button { _ = library.applyPreset(id: preset.id) } label: { Image(systemName: "play.fill") }
                                        .accessibilityLabel(L("应用预设：", "Apply preset: ") + preset.name)
                                    Menu {
                                        Button(L("重命名", "Rename")) { editingID = preset.id; name = preset.name; validationError = false; editing = true }
                                        Button(L("删除预设", "Delete Preset"), role: .destructive) {
                                            store.delete(preset.id)
                                            if library.workflow.configuration.presetID == preset.id { library.workflow.setPreset(nil) }
                                        }
                                    } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel(L("预设选项：", "Preset options: ") + preset.name)
                                }
                            }
                        }
                    }.frame(maxHeight: 220)
                }
                Button(L("保存当前混音…", "Save Current Mix…")) { editingID = nil; name = ""; validationError = false; editing = true }
                    .disabled(store.presets.count >= 100)
            }.padding(20).frame(width: 350).foregroundStyle(AppPalette.ink).background(AppPalette.paper)
            .sheet(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(editingID == nil ? L("保存混音", "Save Mix") : L("重命名混音", "Rename Mix")).font(.headline)
                    TextField(L("预设名称", "Preset name"), text: $name)
                    if validationError {
                        Text(L("请输入不同的名称，最多 80 个字符。", "Use a unique name, up to 80 characters."))
                            .font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button(L("取消", "Cancel")) { editing = false }.keyboardShortcut(.cancelAction)
                        Button(L("保存", "Save")) {
                            let saved = editingID.map { store.rename($0, to: name) } ?? library.saveCurrentPreset(named: name)
                            validationError = !saved
                            if saved { editing = false }
                        }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(24).frame(width: 340)
            }
        }
    }
}
#endif
