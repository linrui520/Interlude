import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

private struct StudioTrack: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var detail: String
    var path: String?
    var duration: Double
    var resource: String?
    var displayTitle: String {
        switch resource {
        case "Stillroom": return L(title, "Stillroom")
        case "Daylight": return L(title, "Daylight Drift")
        case "Nocturne": return L(title, "Night Flight")
        default: return title
        }
    }
    var displayDetail: String {
        resource == nil ? L("本地音频", "Local audio") : L("间奏原创 · 环境音乐", "Interlude Originals · Ambient")
    }

    var url: URL? {
        if let resource {
            if let bundled = Bundle.main.url(forResource: resource, withExtension: "m4a") { return bundled }
            let installed = URL(fileURLWithPath: "/Library/Application Support/Interlude/Music", isDirectory: true)
                .appendingPathComponent(resource).appendingPathExtension("m4a")
            return FileManager.default.isReadableFile(atPath: installed.path) ? installed : nil
        }
        return path.map { URL(fileURLWithPath: $0) }
    }
    static let originals = [
        StudioTrack(id: "stillroom", title: "静室来信", detail: "间奏原创 · 环境音乐", duration: 63, resource: "Stillroom"),
        StudioTrack(id: "daylight", title: "午后漫游", detail: "间奏原创 · 环境音乐", duration: 67, resource: "Daylight"),
        StudioTrack(id: "nocturne", title: "夜航", detail: "间奏原创 · 环境音乐", duration: 71, resource: "Nocturne")
    ]
}

private struct PersonalPlaylist: Identifiable, Codable {
    var id = UUID().uuidString
    var name: String
    var trackIDs = [String]()
}

@MainActor
final class MusicModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published fileprivate var tracks = [StudioTrack]()
    @Published fileprivate var selected: String?
    @Published private(set) var isPlaying = false
    @Published fileprivate var elapsed = 0.0
    @Published fileprivate var volume: Double = 0.65 {
        didSet {
            guard hasAccess else { return }
            player?.volume = Float(volume)
            settings.set(volume, forKey: preferencePrefix + ".volume")
        }
    }
    @Published fileprivate var error: String?
    private let settings: UserDefaults
    private let preferencePrefix: String
    private let includeOriginals: Bool
    private let allowsImport: Bool
    private let requiresConsent: Bool
    @Published private(set) var hasAccess: Bool
    private var accessGeneration = 0
    private weak var importPanel: NSOpenPanel?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var fadingPlayer: AVAudioPlayer?
    private var finishFadeTask: Task<Void, Never>?
    var fadeEnabled = true {
        didSet {
            if !fadeEnabled {
                stopOutgoingFade()
                player?.setVolume(Float(volume), fadeDuration: 0)
            }
        }
    }
    @Published fileprivate var playlists = [PersonalPlaylist]()
    @Published fileprivate var activePlaylistID: String?
    @Published fileprivate var shuffle = false
    @Published fileprivate var repeatOne = false
    private var shuffledQueue = [String]()
    private var playHistory = [String]()
    fileprivate var activePlaylist: PersonalPlaylist? { playlists.first { $0.id == activePlaylistID } }
    fileprivate var visibleTracks: [StudioTrack] {
        guard let list = activePlaylist else { return tracks }
        let lookup = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return list.trackIDs.compactMap { lookup[$0] }
    }
    var supportsImports: Bool { allowsImport && hasAccess }
    fileprivate var track: StudioTrack? { tracks.first { $0.id == selected } }
    var currentTitle: String {
        if let track { return track.displayTitle }
        if !hasAccess { return L("个人音乐", "Personal music") }
        return allowsImport ? L("请导入音乐", "Add your music") : L("环境音乐未安装", "Ambient music is not installed")
    }

    init(includeOriginals: Bool = true, settings: UserDefaults = .standard,
         preferencePrefix: String = "interlude.music", allowsImport: Bool = true, requiresConsent: Bool = false) {
        self.settings = settings
        self.preferencePrefix = preferencePrefix
        self.includeOriginals = includeOriginals
        self.allowsImport = allowsImport
        self.requiresConsent = requiresConsent
        self.hasAccess = !requiresConsent
        super.init()
        if hasAccess { restoreLibrary() }
    }

    func setPersonalAccess(_ granted: Bool) {
        guard requiresConsent, granted != hasAccess else { return }
        accessGeneration += 1
        hasAccess = granted
        if granted {
            restoreLibrary()
        } else {
            importPanel?.cancel(nil)
            importPanel = nil
            pausePlayback()
            player = nil
            tracks.removeAll()
            playlists.removeAll()
            activePlaylistID = nil
            shuffle = false
            repeatOne = false
            clearShuffleQueue()
            selected = nil
            elapsed = 0
            error = nil
            volume = 0.65
        }
    }

    private func restoreLibrary() {
        tracks = includeOriginals ? StudioTrack.originals.filter { $0.url != nil } : []
        if supportsImports { tracks += Self.savedImports(in: settings, prefix: preferencePrefix) }
        if supportsImports, let data = settings.data(forKey: preferencePrefix + ".playlists"),
           let saved = try? JSONDecoder().decode([PersonalPlaylist].self, from: data) {
            let valid = Set(tracks.filter { $0.path != nil }.map(\.id))
            playlists = saved.map { item in
                var list = item
                list.trackIDs = list.trackIDs.filter(valid.contains)
                return list
            }
        }
        shuffle = settings.bool(forKey: preferencePrefix + ".shuffle")
        repeatOne = settings.bool(forKey: preferencePrefix + ".repeatOne")
        fadeEnabled = settings.object(forKey: "interlude.settings.musicFade") as? Bool ?? true
        let last = settings.string(forKey: preferencePrefix + ".selection")
        selected = tracks.first { $0.id == last }?.id ?? tracks.first?.id
        if settings.object(forKey: preferencePrefix + ".volume") != nil {
            volume = min(1, max(0, settings.double(forKey: preferencePrefix + ".volume")))
        }
    }

    private static func savedImports(in source: UserDefaults, prefix: String) -> [StudioTrack] {
        guard let data = source.data(forKey: prefix + ".library"),
              let saved = try? JSONDecoder().decode([StudioTrack].self, from: data) else { return [] }
        return saved.filter { $0.path?.hasPrefix("/") == true && $0.resource == nil && $0.duration > 0 }
    }

    /// Runs only after consent. A completed migration stays completed when users remove migrated songs.
    func migrateLegacyImports(from sources: [UserDefaults]) {
        let marker = preferencePrefix + ".didMigrateLegacyLibraries"
        guard requiresConsent, supportsImports, !settings.bool(forKey: marker) else { return }
        var paths = Set(tracks.compactMap { $0.url?.standardizedFileURL.path })
        var identifiers = Set(tracks.map(\.id))
        for source in sources {
            for var entry in Self.savedImports(in: source, prefix: "interlude.music") {
                guard let path = entry.url?.standardizedFileURL.path, paths.insert(path).inserted else { continue }
                if identifiers.contains(entry.id) { entry.id = UUID().uuidString }
                identifiers.insert(entry.id)
                entry.path = path
                tracks.append(entry)
            }
        }
        if selected == nil, let first = tracks.first { choose(first.id, play: false) }
        persist()
        settings.set(true, forKey: marker)
    }

    private func persist() {
        guard supportsImports else { return }
        let imported = tracks.filter { $0.path != nil }
        if let data = try? JSONEncoder().encode(imported) { settings.set(data, forKey: preferencePrefix + ".library") }
    }

    private func savePlaylists() {
        guard supportsImports, let data = try? JSONEncoder().encode(playlists) else { return }
        settings.set(data, forKey: preferencePrefix + ".playlists")
    }

    @discardableResult
    fileprivate func savePlaylist(name: String, replacing id: String?) -> String? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsImports, !title.isEmpty else { return nil }
        if let id {
            guard let index = playlists.firstIndex(where: { $0.id == id }) else { return nil }
            playlists[index].name = title
            savePlaylists()
            return id
        }
        let list = PersonalPlaylist(name: title)
        playlists.append(list)
        savePlaylists()
        return list.id
    }

    fileprivate func selectPlaylist(_ id: String?) {
        guard supportsImports, id == nil || playlists.contains(where: { $0.id == id }) else { return }
        activePlaylistID = id
        clearShuffleQueue()
        if !visibleTracks.contains(where: { $0.id == selected }) { choose(visibleTracks.first?.id, play: false) }
    }

    fileprivate func deletePlaylist(_ id: String) {
        guard supportsImports else { return }
        playlists.removeAll { $0.id == id }
        if activePlaylistID == id { selectPlaylist(nil) }
        savePlaylists()
    }

    fileprivate func setMembership(trackID: String, listID: String, included: Bool) {
        guard supportsImports, tracks.contains(where: { $0.id == trackID && $0.resource == nil }),
              let index = playlists.firstIndex(where: { $0.id == listID }) else { return }
        if included {
            if !playlists[index].trackIDs.contains(trackID) { playlists[index].trackIDs.append(trackID) }
        } else {
            playlists[index].trackIDs.removeAll { $0 == trackID }
        }
        if activePlaylistID == listID { selectPlaylist(listID) }
        savePlaylists()
    }

    fileprivate func toggleShuffle() {
        guard hasAccess else { return }
        shuffle.toggle()
        clearShuffleQueue()
        settings.set(shuffle, forKey: preferencePrefix + ".shuffle")
    }

    fileprivate func toggleRepeat() {
        guard hasAccess else { return }
        repeatOne.toggle()
        settings.set(repeatOne, forKey: preferencePrefix + ".repeatOne")
    }

    private func clearShuffleQueue() {
        shuffledQueue.removeAll()
        playHistory.removeAll()
    }

    fileprivate func choose(_ id: String?, play: Bool = true) {
        guard hasAccess else { return }
        if play && isPlaying { fadeOutPlayback() } else { pausePlayback() }
        player = nil
        selected = id
        shuffledQueue.removeAll { $0 == id }
        elapsed = 0
        settings.set(id, forKey: preferencePrefix + ".selection")
        if play, id != nil { start() }
    }

    private func start() {
        guard hasAccess else { return }
        guard let track else { if activePlaylistID == nil { importAudio() }; return }
        guard let url = track.url, FileManager.default.fileExists(atPath: url.path) else {
            error = allowsImport
                ? L("找不到《" + currentTitle + "》的音频文件。请从新位置重新导入。", "The file for “" + currentTitle + "” is missing. Import it from its new location.")
                : L("无法找到环境音乐。请通过安装包重新安装环境音乐组件。", "The ambient audio file is missing. Reinstall the Ambient Music component.")
            return
        }
        do {
            if player == nil {
                let loaded = try AVAudioPlayer(contentsOf: url)
                loaded.volume = Float(volume)
                loaded.delegate = self
                loaded.currentTime = elapsed
                player = loaded
            }
            player?.volume = fadeEnabled ? 0 : Float(volume)
            guard let player, player.play() else {
                error = L("播放未能开始，请检查声音输出设备后再试。", "Playback could not start. Check your audio output device.")
                return
            }
            if fadeEnabled { player.setVolume(Float(volume), fadeDuration: 0.6) }
            isPlaying = true
            let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isPlaying else { return }
                    self.elapsed = self.player?.currentTime ?? 0
                }
            }
            timer?.invalidate()
            timer = tick
            RunLoop.main.add(tick, forMode: .common)
        } catch {
            self.error = L("无法播放《" + currentTitle + "》。请确认文件能在本机打开。", "Cannot play “" + currentTitle + "”. Check that the file opens on this Mac.")
        }
    }

    private func stopOutgoingFade() {
        finishFadeTask?.cancel()
        finishFadeTask = nil
        fadingPlayer?.stop()
        fadingPlayer = nil
    }

    var presetTrackID: String? { selected }
    var presetPlaylistID: String? { activePlaylistID }
    var presetVolume: Double { volume }

    /// Applies a saved selection without invoking an import panel or bypassing personal access.
    @discardableResult
    func applyPresetSelection(trackID: String?, playlistID: String?, volume level: Double, play: Bool) -> Bool {
        guard hasAccess, level.isFinite, (0...1).contains(level) else { return false }
        pausePlayback()
        volume = level
        var valid = true
        if allowsImport {
            if let playlistID, !playlists.contains(where: { $0.id == playlistID }) { valid = false }
            activePlaylistID = playlists.contains(where: { $0.id == playlistID }) ? playlistID : nil
            clearShuffleQueue()
        }
        guard let trackID else { selected = nil; elapsed = 0; return !play && valid }
        guard visibleTracks.contains(where: { $0.id == trackID }) else {
            selected = nil
            elapsed = 0
            return false
        }
        choose(trackID, play: play)
        return valid && (!play || isPlaying)
    }

    func setPresetVolume(_ level: Double) {
        guard hasAccess, level.isFinite, (0...1).contains(level) else { return }
        volume = level
    }

    func fadeForSleep() {
        if isPlaying { fadeOutPlayback(force: true, duration: 0.8) }
    }

    var playingOriginalID: String? { isPlaying && track?.resource != nil ? selected : nil }

    @discardableResult
    func chooseOriginal(_ id: String) -> Bool {
        guard hasAccess, tracks.contains(where: { $0.id == id && $0.resource != nil }) else { return false }
        if selected != id || !isPlaying { choose(id) }
        return true
    }

    func releaseAudio() {
        pausePlayback()
        player?.delegate = nil
        player = nil
    }

    private func fadeOutPlayback(force: Bool = false, duration: Double = 0.6) {
        guard (force || fadeEnabled), let outgoing = player, outgoing.isPlaying else { pausePlayback(); return }
        stopOutgoingFade()
        elapsed = outgoing.currentTime
        timer?.invalidate()
        timer = nil
        isPlaying = false
        outgoing.delegate = nil
        player = nil
        fadingPlayer = outgoing
        outgoing.setVolume(0, fadeDuration: duration)
        finishFadeTask = Task { @MainActor [weak self, weak outgoing] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, let outgoing, self.fadingPlayer === outgoing else { return }
            outgoing.stop()
            self.fadingPlayer = nil
            self.finishFadeTask = nil
        }
    }

    func pausePlayback() {
        stopOutgoingFade()
        player?.pause()
        if let player { elapsed = player.currentTime }
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func togglePlayback() {
        guard hasAccess else { return }
        if isPlaying { fadeOutPlayback() } else { stopOutgoingFade(); start() }
    }

    func previousTrack() { step(-1) }
    func nextTrack() { step(1) }

    fileprivate func step(_ delta: Int) {
        let ids = visibleTracks.map(\.id)
        guard hasAccess, !ids.isEmpty else { return }
        let index = ids.firstIndex { $0 == selected } ?? 0
        var next = ids[(index + delta + ids.count) % ids.count]
        if shuffle && ids.count > 1 {
            if delta < 0, let previous = playHistory.popLast() {
                if let selected { shuffledQueue.append(selected) }
                next = previous
            } else if delta > 0 {
                if shuffledQueue.isEmpty { shuffledQueue = ids.filter { $0 != selected }.shuffled() }
                if let candidate = shuffledQueue.popLast() { next = candidate }
                if let selected { playHistory.append(selected) }
                if playHistory.count > ids.count { playHistory.removeFirst() }
            }
        }
        choose(next)
    }

    fileprivate func seek(_ second: Double) {
        guard hasAccess, let track else { return }
        elapsed = min(max(second, 0), max(0, track.duration - 0.05))
        player?.currentTime = elapsed
    }

    fileprivate func remove(_ id: String) {
        guard supportsImports, tracks.contains(where: { $0.id == id && $0.path != nil }) else { return }
        tracks.removeAll { $0.id == id }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == id } }
        clearShuffleQueue()
        if selected == id { choose(visibleTracks.first?.id, play: false) }
        savePlaylists()
        persist()
    }

    func importAudio() {
        guard supportsImports else { return }
        if let importPanel { importPanel.makeKeyAndOrderFront(nil); return }
        let generation = accessGeneration
        let panel = NSOpenPanel()
        importPanel = panel
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("加入音乐库", "Add to Library")
        panel.title = L("选择本地音频", "Choose Local Audio")
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, generation == self.accessGeneration else { return }
                self.importPanel = nil
                if response == .OK { await self.importFiles(panel.urls) }
            }
        }
    }

    fileprivate func acceptDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard supportsImports, !files.isEmpty else { return false }
        let generation = accessGeneration
        Task { @MainActor in
            if generation == accessGeneration { await importFiles(files) }
        }
        return true
    }

    func importFiles(_ urls: [URL]) async {
        guard supportsImports else { return }
        let generation = accessGeneration
        let destination = activePlaylistID
        var requestedPaths = [String]()
        var rejected = [String]()
        var imported = [StudioTrack]()
        for url in urls {
            guard generation == accessGeneration else { return }
            guard url.isFileURL else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let key = url.standardizedFileURL.path
            requestedPaths.append(key)
            guard !tracks.contains(where: { $0.path == key }) else { continue }
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds,
                  generation == accessGeneration, duration.isFinite, duration > 0,
                  let audioTracks = try? await asset.loadTracks(withMediaType: .audio), !audioTracks.isEmpty else {
                rejected.append(url.lastPathComponent)
                continue
            }
            imported.append(StudioTrack(id: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent,
                                      detail: "本地音频", path: key, duration: duration))
        }
        guard generation == accessGeneration else { return }
        // Commit against the current library after every file has finished loading.
        var existingPaths = Set(tracks.compactMap(\.path))
        let added = imported.filter { entry in
            guard let path = entry.path else { return false }
            return existingPaths.insert(path).inserted
        }
        tracks += added
        if !added.isEmpty { clearShuffleQueue() }
        if let index = playlists.firstIndex(where: { $0.id == destination }) {
            let byPath = Dictionary(tracks.compactMap { item in item.path.map { ($0, item.id) } },
                                    uniquingKeysWith: { first, _ in first })
            var included = Set(playlists[index].trackIDs)
            playlists[index].trackIDs += requestedPaths.compactMap { path in
                guard let id = byPath[path], included.insert(id).inserted else { return nil }
                return id
            }
            clearShuffleQueue()
            savePlaylists()
        }
        if selected == nil, let first = visibleTracks.first { choose(first.id, play: false) }
        persist()
        if !rejected.isEmpty { error = L("这些文件没有可读取的音轨：", "No readable audio was found in these files: ") + rejected.joined(separator: ", ") }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully ok: Bool) {
        Task { @MainActor in
            guard self.hasAccess, self.player === player, self.isPlaying else { return }
            if ok {
                if self.repeatOne { self.choose(self.selected) } else { self.nextTrack() }
            } else {
                self.pausePlayback()
                self.error = L("音频播放中断，请重新播放。", "Playback was interrupted. Try playing the track again.")
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.hasAccess, self.player === player else { return }
            self.pausePlayback()
            self.player = nil
            self.error = L("无法读取音频，请检查文件后重新导入。", "Cannot read this audio file. Check the file and import it again.")
        }
    }
}

private let recordInk = Color(red: 0.115, green: 0.124, blue: 0.116)
private let recordPaper = Color(red: 0.97, green: 0.96, blue: 0.92)
private let recordAccents = [Color(red: 0.95, green: 0.43, blue: 0.23), Color(red: 0.77, green: 0.70, blue: 0.40), Color(red: 0.48, green: 0.66, blue: 0.67)]
private func musicTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    return String(format: "%d:%02d", value/60, value%60)
}

private struct Sleeve: View {
    let variant: Int
    var rotation = 0.0
    var body: some View {
        Canvas { ctx, size in
            let width = size.width, height = size.height, s = max(width,height)
            let color = recordAccents[variant % recordAccents.count]
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
            for i in 0..<28 {
                var line = Path()
                let x = CGFloat(i) * s / 12 - s
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x + height, y: height))
                ctx.stroke(line, with: .color(.black.opacity(0.1)), lineWidth: max(0.5, s / 325))
            }
            let diameter = s*0.99
            ctx.translateBy(x: width*0.57, y: height*0.55)
            ctx.rotate(by: .degrees(rotation))
            let rect = CGRect(x: -diameter/2,y: -diameter/2,width: diameter,height: diameter)
            ctx.fill(Path(ellipseIn: rect), with: .color(recordInk))
            for ring in 0..<32 {
                let inset = s * (0.011 + 0.0088 * Double(ring))
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: inset, dy: inset)), with: .color(.white.opacity(ring%4 == 0 ? 0.2 : 0.075)), lineWidth: max(0.45, s/350))
            }
            let label = rect.insetBy(dx: s*0.32, dy: s*0.32)
            ctx.fill(Path(ellipseIn: label), with: .color(color))
            var split = Path()
            split.addArc(center: .zero, radius: label.width/2, startAngle: .degrees(35), endAngle: .degrees(215), clockwise: false)
            split.closeSubpath()
            ctx.fill(split, with: .color(recordPaper))
            ctx.fill(Path(ellipseIn: CGRect(x: -s*0.013, y: -s*0.013,width: s*0.026,height:s*0.026)), with: .color(recordInk))
        }
        .accessibilityHidden(true)
    }
}

struct MusicPage: View {
    @ObservedObject var model: MusicModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    private var swapAnimation: Animation? {
        reduceMotion || !model.hasAccess ? nil : .spring(response: 0.38, dampingFraction: 0.92)
    }
    private var index: Int { model.tracks.firstIndex { $0.id == model.selected } ?? 0 }
    @Environment(\.motionAmount) private var motionAmount
    @State private var editingPlaylist = false
    @State private var renamingID: String?
    @State private var playlistName = ""
    @State private var deletingPlaylist = false
    @State private var dragTargeted = false
    @State private var hovering: String?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let track = model.track {
                playerCard(for: track)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "music.note.list").font(.system(size: 30))
                    Text(model.supportsImports
                         ? (model.activePlaylist == nil ? L("音乐库为空", "Your library is empty") : L("歌单为空", "This playlist is empty"))
                         : L("环境音乐未安装", "Ambient music is not installed")).font(.headline)
                    Text(model.supportsImports
                         ? L("拖入音频文件，或点按“导入音乐”。", "Drop audio files here or choose Import Music.")
                         : L("在安装包中选择“原创环境音乐”即可添加。", "Choose Ambient Music in the Interlude installer.")).font(.subheadline)
                }
                .foregroundStyle(recordPaper)
                .frame(maxWidth: .infinity).frame(height: 210)
                .background(recordInk, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(alignment: .center, spacing: 9) {
                if model.supportsImports { playlistMenu }
                else { Text(L("音乐库", "Library")).font(.system(size: 18, weight: .semibold)) }
                let count = model.visibleTracks.count
                Text(L("\(count) 首", "\(count) " + (count == 1 ? "track" : "tracks")))
                    .font(.caption).foregroundStyle(AppPalette.muted)
                Spacer()
                if model.supportsImports {
                    Button(action: model.importAudio) {
                        Label(L("导入音乐", "Import Music"), systemImage: "plus").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 29)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppPalette.line, lineWidth: 1))
                    }.buttonStyle(InterludeButtonStyle())
                }
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(model.visibleTracks.enumerated()), id: \.element.id) { position, item in
                        row(item, position: position)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 5 * motionAmount)))
                    }
                }
                .animation(swapAnimation, value: model.visibleTracks.map(\.id))
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in model.acceptDrop(urls) }
            isTargeted: { dragTargeted = model.supportsImports && $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AppPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [5]))
                .opacity(dragTargeted ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: dragTargeted)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $editingPlaylist) {
            VStack(alignment: .leading, spacing: 14) {
                Text(renamingID == nil ? L("新建歌单", "New Playlist") : L("重命名歌单", "Rename Playlist")).font(.headline)
                TextField(L("歌单名称", "Playlist name"), text: $playlistName)
                HStack {
                    Spacer()
                    Button(L("取消", "Cancel")) { editingPlaylist = false }.keyboardShortcut(.cancelAction)
                    Button(L("保存", "Save")) {
                        if let id = model.savePlaylist(name: playlistName, replacing: renamingID) {
                            model.selectPlaylist(id)
                            editingPlaylist = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 350)
        }
        .confirmationDialog(L("删除此歌单？", "Delete this playlist?"), isPresented: $deletingPlaylist) {
            Button(L("删除歌单", "Delete Playlist"), role: .destructive) {
                if let id = model.activePlaylistID { model.deletePlaylist(id) }
            }
        } message: { Text(L("曲目仍保存在音乐库中。", "The tracks will stay in your library.")) }
        .alert(L("音乐播放器", "Music Player"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("好", "OK")) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.selected) { _, _ in scrubbing = false }
    }

    private var playlistMenu: some View {
        Menu {
            Button(L("所有音乐", "All Music")) { model.selectPlaylist(nil) }
            ForEach(model.playlists) { item in
                Button(item.name) { model.selectPlaylist(item.id) }
            }
            Divider()
            Button(L("新建歌单…", "New Playlist…")) {
                renamingID = nil; playlistName = ""; editingPlaylist = true
            }
            if let list = model.activePlaylist {
                Button(L("重命名歌单…", "Rename Playlist…")) {
                    renamingID = list.id; playlistName = list.name; editingPlaylist = true
                }
                Button(L("删除歌单…", "Delete Playlist…"), role: .destructive) { deletingPlaylist = true }
            }
        } label: {
            Text(model.activePlaylist?.name ?? L("所有音乐", "All Music"))
                .lineLimit(1).font(.system(size: 16, weight: .semibold))
        }.fixedSize()
    }

    @ViewBuilder private func actions(for item: StudioTrack) -> some View {
        if model.supportsImports, item.path != nil {
            if !model.playlists.isEmpty {
                Menu(L("加入歌单", "Add to Playlist")) {
                    ForEach(model.playlists) { list in
                        Button(list.name) { model.setMembership(trackID: item.id, listID: list.id, included: true) }
                            .disabled(list.trackIDs.contains(item.id))
                    }
                }
            }
            if let list = model.activePlaylist {
                Button(L("从当前歌单移除", "Remove from Playlist")) {
                    model.setMembership(trackID: item.id, listID: list.id, included: false)
                }
            }
            Button(L("从音乐库移除", "Remove from Library")) { model.remove(item.id) }
        }
    }

    private func row(_ item: StudioTrack, position: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                if model.selected == item.id { model.togglePlayback() }
                else { model.choose(item.id) }
            } label: {
                HStack(spacing: 13) {
                    Text(String(format: "%02d", position + 1)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppPalette.muted).frame(width: 19)
                    Sleeve(variant: position).frame(width: 35, height: 35).clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(item.displayDetail).font(.system(size: 10)).foregroundStyle(AppPalette.muted)
                    }
                    Spacer()
                    if model.selected == item.id {
                        Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "music.note")
                            .font(.caption).foregroundStyle(AppPalette.accent)
                    }
                    Text(musicTime(item.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppPalette.muted)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if model.supportsImports {
                Menu { actions(for: item) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L("曲目选项", "Track options"))
            }
        }
        .padding(.horizontal, 12).frame(height: 53)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppPalette.ink.opacity(model.selected == item.id ? 0.065 : (hovering == item.id ? 0.035 : 0))))
        .onHover { hover in if hover { hovering = item.id } else if hovering == item.id { hovering = nil } }
        .contextMenu { actions(for: item) }
    }

    private func playerCard(for track: StudioTrack) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1/30, paused: reduceMotion || motionAmount == 0 || !model.isPlaying)) { time in
                    let base = model.elapsed
                    Sleeve(variant: index, rotation: reduceMotion ? 0 : (model.isPlaying ? model.playhead(for: time.date) : base) * 12 * motionAmount)
                }
                .overlay(alignment: .topLeading) {
                    Text("INTERLUDE  /  \(String(format: "%02d", index + 1))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2)
                        .foregroundStyle(recordInk).padding(12)
                }
                .id(track.id)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 1 - 0.05 * motionAmount)))
            }
            .frame(width: 208)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(swapAnimation, value: track.id)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(model.isPlaying ? recordAccents[0] : .white.opacity(0.45)).frame(width: 6, height: 6)
                    Text(model.isPlaying ? L("正在播放", "Now playing") : L("当前曲目", "Current track")).font(.system(size: 11, weight: .medium))
                }.foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.displayTitle).font(.system(size: 27, weight: .semibold)).foregroundStyle(recordPaper).lineLimit(1)
                        Text(track.displayDetail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.60))
                    }
                    .id(track.id)
                    .transition(reduceMotion ? .identity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 7 * motionAmount)),
                        removal: .opacity.combined(with: .offset(y: -4 * motionAmount))))
                }
                .animation(swapAnimation, value: track.id)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(track.displayTitle + ", " + track.displayDetail)
                Spacer(minLength: 8)
                HStack(spacing: 9) {
                    Text(musicTime(scrubbing ? scrubValue : model.elapsed))
                    Slider(value: Binding(get: { scrubbing ? scrubValue : model.elapsed },
                                          set: { value in scrubValue = value; model.seek(value) }),
                           in: 0...max(1, track.duration), onEditingChanged: { editing in
                        if editing { scrubValue = model.elapsed }
                        scrubbing = editing
                    })
                    .tint(AppPalette.accent).accessibilityLabel(L("播放进度", "Playback position"))
                    Text(musicTime(track.duration))
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
                HStack(spacing: 10) {
                    modeControl("shuffle", L("随机播放", "Shuffle"), active: model.shuffle, action: model.toggleShuffle)
                    transport("backward.end.fill", L("上一首", "Previous track"), action: model.previousTrack)
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(recordInk)
                            .frame(width: 35, height: 35).background(recordPaper, in: Circle())
                    }.buttonStyle(InterludeButtonStyle(scale: 0.92)).accessibilityLabel(model.isPlaying ? L("暂停", "Pause") : L("播放", "Play"))
                    transport("forward.end.fill", L("下一首", "Next track"), action: model.nextTrack)
                    modeControl("repeat.1", L("单曲循环", "Repeat one"), active: model.repeatOne, action: model.toggleRepeat)
                    Spacer()
                    Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    Slider(value: $model.volume, in: 0...1).frame(maxWidth: 78)
                        .accessibilityLabel(L("音量", "Volume")).tint(recordPaper)
                }.padding(.top, 9)
            }
            .padding(.vertical, 18).padding(.horizontal, 23)
            .environment(\.colorScheme, .dark)
        }
        .frame(height: 210)
        .background(recordInk)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func modeControl(_ icon: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? AppPalette.accent : recordPaper.opacity(0.6))
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(InterludeButtonStyle()).help(title).accessibilityLabel(title)
        .accessibilityValue(active ? L("开", "On") : L("关", "Off"))
    }

    private func transport(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(recordPaper)
                .frame(width: 25,height: 30).contentShape(Rectangle())
        }.buttonStyle(InterludeButtonStyle()).accessibilityLabel(title).help(title)
    }
}

private extension MusicModel {
    func playhead(for date: Date) -> Double {
        player?.currentTime ?? elapsed
    }
}
