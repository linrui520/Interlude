import AVFoundation
import SwiftUI

enum NoiseKind: String, CaseIterable, Identifiable, Sendable {
    case rain, ocean, forest, cafe
    var id: Self { self }
    var title: String {
        switch self {
        case .rain: return L("雨声", "Rain")
        case .ocean: return L("海浪", "Ocean")
        case .forest: return L("森林", "Forest")
        case .cafe: return L("咖啡馆", "Café")
        }
    }
    var symbol: String {
        switch self {
        case .rain: return "cloud.rain"
        case .ocean: return "water.waves"
        case .forest: return "tree"
        case .cafe: return "cup.and.saucer"
        }
    }
    var levelKey: String { "interlude.noise." + rawValue + ".volume" }
}

/// Produces a mono PCM loop in memory. A short overlap joins the end of the stream to its beginning.
enum NoiseSynthesis {
    private struct Generator {
        var state: UInt32
        mutating func sample() -> Double {
            state = 1664525 &* state &+ 1013904223
            return Double(state) / 2147483648 - 1
        }
    }

    static func wave(_ kind: NoiseKind) -> Data? {
        let rate = 22050
        let frames = rate * 18
        let overlap = rate / 2
        let tau = 2 * Double.pi
        var random = Generator(state: UInt32(51881 + (NoiseKind.allCases.firstIndex(of: kind) ?? 0) * 971))
        var samples = [Float](repeating: 0, count: frames + overlap)
        var slow = 0.0, medium = 0.0, fast = 0.0, previous = 0.0
        var transient = 0.0, pitch = 0.0, phase = 0.0
        for i in samples.indices {
            if i.isMultiple(of: 2048), Task.isCancelled { return nil }
            let t = Double(i) / Double(rate)
            let noise = random.sample()
            slow += 0.014 * (noise - slow)
            medium += 0.13 * (noise - medium)
            fast += 0.56 * (noise - fast)
            let sound: Double
            switch kind {
            case .rain:
                if noise > 0.99965 {
                    transient = 0.13
                    pitch = 1600 + 800 * random.sample()
                    phase = 0
                }
                phase += tau * pitch / Double(rate)
                transient *= 0.995
                sound = 0.48 * (fast - 0.45 * medium) + 0.22 * slow + transient * sin(phase)
            case .ocean:
                let swell = 0.5 + 0.5 * sin(t * 0.84 + 0.38 * sin(t * 0.42))
                sound = (0.32 + 0.85 * swell) * (1.8 * slow + 0.36 * medium) + 0.29 * pow(swell, 3) * fast
            case .forest:
                // Wind in leaves, with occasional short descending bird calls.
                let pulse = t.truncatingRemainder(dividingBy: 5.34)
                let call = min(0.48, max(0, pulse - 1.25))
                let envelope = pow(sin(Double.pi * call / 0.48), 2)
                let chirp = sin(tau * (2350 * call - 1400 * call * call) + 0.23 * sin(40 * call))
                sound = (0.58 + 0.24 * sin(t * 0.63)) * (0.6 * slow + 0.52 * medium) + 0.20 * envelope * chirp
            case .cafe:
                // Two low, wordless murmur textures and occasional decaying ceramic taps.
                if noise > 0.99997 {
                    transient = 0.20
                    pitch = 1850 + 320 * random.sample()
                    phase = 0
                }
                phase += tau * pitch / Double(rate)
                transient *= 0.9991
                let cadence = 0.58 + 0.16 * sin(t * 3.7 + sin(t * 1.9)) + 0.17 * sin(t * 5.3)
                let murmur = sin(tau * 121 * t + 3.0 * sin(t * 6.3)) + 0.43 * sin(tau * 183 * t + sin(t * 8.1))
                sound = cadence * (1.8 * slow + 0.60 * medium + 0.11 * murmur)
                    + transient * (sin(phase) + 0.21 * sin(phase * 1.56))
            }
            previous += 0.75 * (sound - previous)
            samples[i] = Float(0.235 * tanh(previous * 2.6))
        }
        var data = Data()
        data.reserveCapacity(44 + frames * 2)
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func number<T: FixedWidthInteger>(_ x: T) {
            var little = x.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + frames * 2)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(rate)); number(UInt32(rate * 2)); number(UInt16(2)); number(UInt16(16))
        text("data"); number(UInt32(frames * 2))
        var pcm = [Int16](repeating: 0, count: frames)
        for i in pcm.indices {
            if i.isMultiple(of: 4096), Task.isCancelled { return nil }
            var value = samples[i]
            if i < overlap {
                let u = Float(i) / Float(overlap)
                let blend = u * u * (3 - 2 * u)
                value = samples[frames + i] * (1 - blend) + value * blend
            }
            pcm[i] = Int16((value * 32767).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

@MainActor
final class NoiseMixer: ObservableObject {
    private final class Voice {
        var rendering: Task<Data?, Never>?
        var starting: Task<Void, Never>?
        var stopping: Task<Void, Never>?
        var player: AVAudioPlayer?
        func stop() {
            rendering?.cancel()
            starting?.cancel()
            stopping?.cancel()
            player?.stop()
            player = nil
        }
        deinit { rendering?.cancel(); starting?.cancel(); stopping?.cancel() }
    }

    @Published private(set) var enabled = Set<NoiseKind>()
    @Published private(set) var levels: [NoiseKind: Double] = [:]
    @Published var error: String?
    private var voices: [NoiseKind: Voice] = [:]
    private let settings: UserDefaults

    init(settings: UserDefaults = .standard) {
        self.settings = settings
        for kind in NoiseKind.allCases {
            let stored = settings.object(forKey: kind.levelKey) as? NSNumber
            let value = stored?.doubleValue ?? 0.5
            levels[kind] = value.isFinite ? min(1, max(0, value)) : 0.5
        }
    }

    func setLevel(_ level: Double, for kind: NoiseKind) {
        guard level.isFinite else { return }
        let value = min(1, max(0, level))
        levels[kind] = value
        settings.set(value, forKey: kind.levelKey)
        if enabled.contains(kind) { voices[kind]?.player?.setVolume(Float(value), fadeDuration: 0.1) }
    }

    func setEnabled(_ value: Bool, for kind: NoiseKind) {
        guard value != enabled.contains(kind) else { return }
        if !value { fadeOut(kind, duration: 0.45); return }
        enabled.insert(kind)
        if let voice = voices[kind], let player = voice.player, player.isPlaying {
            voice.stopping?.cancel()
            voice.stopping = nil
            player.setVolume(Float(levels[kind] ?? 0.5), fadeDuration: 0.35)
            return
        }
        voices.removeValue(forKey: kind)?.stop()
        let voice = Voice()
        voices[kind] = voice
        let render = Task.detached(priority: .userInitiated) { NoiseSynthesis.wave(kind) }
        voice.rendering = render
        voice.starting = Task { @MainActor [weak self, weak voice] in
            let data = await render.value
            guard !Task.isCancelled, let self, let voice, self.voices[kind] === voice,
                  self.enabled.contains(kind), let data else { return }
            voice.rendering = nil
            voice.starting = nil
            do {
                let player = try AVAudioPlayer(data: data)
                player.numberOfLoops = -1
                player.volume = 0
                voice.player = player
                if player.play() {
                    player.setVolume(Float(self.levels[kind] ?? 0.5), fadeDuration: 0.45)
                    return
                }
            } catch { /* Restore the switch if the current output device cannot play the loop. */ }
            self.removeVoice(kind)
            self.error = L("无法播放声景，请检查音频输出设备。", "Cannot play the soundscape. Check the audio output device.")
        }
    }

    private func removeVoice(_ kind: NoiseKind) {
        enabled.remove(kind)
        voices.removeValue(forKey: kind)?.stop()
    }

    private func fadeOut(_ kind: NoiseKind, duration: Double) {
        enabled.remove(kind)
        guard let voice = voices[kind], let player = voice.player else { removeVoice(kind); return }
        voice.stopping?.cancel()
        player.setVolume(0, fadeDuration: duration)
        voice.stopping = Task { @MainActor [weak self, weak voice] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, let voice, self.voices[kind] === voice else { return }
            self.removeVoice(kind)
        }
    }

    func fadeOutAll() {
        for kind in Array(enabled) { fadeOut(kind, duration: 0.8) }
    }

    func stopAll() {
        for kind in Array(voices.keys) { removeVoice(kind) }
        error = nil
    }
}

@MainActor
final class MusicSleepTimer: ObservableObject {
    enum Mode: Equatable { case minutes, focusEnd }
    @Published private(set) var mode: Mode?
    @Published private(set) var remaining = 0
    private var deadline: Date?
    private var clock: Timer?
    var onFinish: (() -> Void)?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func start(minutes: Int) {
        guard (1...1440).contains(minutes) else { return }
        cancel()
        mode = .minutes
        remaining = minutes * 60
        deadline = now().addingTimeInterval(Double(remaining))
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func atFocusEnd() { cancel(); mode = .focusEnd }
    func focusDidFinish() { if mode == .focusEnd { finish() } }
    func refresh() {
        guard let deadline, mode == .minutes else { return }
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now()))))
        if seconds != remaining { remaining = seconds }
        if seconds == 0 { finish() }
    }
    private func finish() { cancel(); onFinish?() }
    func cancel() { clock?.invalidate(); clock = nil; deadline = nil; mode = nil; remaining = 0 }
    deinit { clock?.invalidate() }
}

struct SoundscapeButton: View {
    @ObservedObject var mixer: NoiseMixer
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label(L("声景", "Mix"), systemImage: "slider.horizontal.3")
                .foregroundStyle(mixer.enabled.isEmpty ? AppPalette.muted : AppPalette.accent)
        }
        .font(.system(size: 11, weight: .medium)).buttonStyle(InterludeButtonStyle())
        .accessibilityValue(L("已开启 \(mixer.enabled.count) 种", "\(mixer.enabled.count) active"))
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("声景混音", "Soundscape Mixer")).font(.headline)
                Text(L("四种本地合成声景，可同时开启并单独调节音量。", "Layer four locally synthesized soundscapes and adjust each volume."))
                    .font(.caption).foregroundStyle(AppPalette.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(NoiseKind.allCases) { kind in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { mixer.enabled.contains(kind) },
                                             set: { mixer.setEnabled($0, for: kind) })) {
                            Label(kind.title, systemImage: kind.symbol)
                        }.toggleStyle(.checkbox).frame(width: 110, alignment: .leading)
                        Slider(value: Binding(get: { mixer.levels[kind] ?? 0.5 },
                                              set: { mixer.setLevel($0, for: kind) }), in: 0...1)
                        .accessibilityLabel(kind.title + L("音量", " volume"))
                    }
                }
            }
            .padding(20).frame(width: 325)
            .tint(AppPalette.accent).foregroundStyle(AppPalette.ink).background(AppPalette.paper)
            .alert(L("声景播放", "Soundscapes"), isPresented: Binding(get: { mixer.error != nil },
                                                                         set: { if !$0 { mixer.error = nil } })) {
                Button(L("好", "OK")) { mixer.error = nil }
            } message: { Text(mixer.error ?? "") }
        }
    }
}

struct MusicSleepButton: View {
    @ObservedObject var timer: MusicSleepTimer
    @State private var showing = false
    @State private var custom = "45"

    private var label: String {
        switch timer.mode {
        case .minutes:
            let s = timer.remaining
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                             : String(format: "%d:%02d", s / 60, s % 60)
        case .focusEnd: return L("专注结束", "Focus end")
        case nil: return L("定时", "Sleep")
        }
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Label(label, systemImage: "moon.zzz")
                .monospacedDigit().foregroundStyle(timer.mode == nil ? AppPalette.muted : AppPalette.accent)
        }
        .font(.system(size: 11, weight: .medium)).buttonStyle(InterludeButtonStyle())
        .help(L("音乐定时关闭", "Music sleep timer"))
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("音乐定时关闭", "Music Sleep Timer")).font(.headline)
                Text(L("时间到了，音乐和声景会淡出。", "Music and soundscapes fade out when the timer ends."))
                    .font(.caption).foregroundStyle(AppPalette.muted)
                HStack {
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button(L("\(minutes) 分钟", "\(minutes) min")) {
                            timer.start(minutes: minutes); showing = false
                        }
                    }
                }
                HStack {
                    TextField(L("自定义分钟", "Custom minutes"), text: $custom).frame(width: 65)
                    Text(L("分钟", "minutes"))
                    Spacer()
                    Button(L("开始", "Start")) { startCustom() }.disabled(!validCustom)
                }
                Button(L("在下次专注结束时关闭", "Stop at the end of the next focus period")) {
                    timer.atFocusEnd(); showing = false
                }
                if timer.mode != nil {
                    Divider()
                    HStack {
                        Text(label).monospacedDigit()
                        Spacer()
                        Button(L("取消定时", "Cancel timer")) { timer.cancel(); showing = false }
                    }
                }
            }
            .padding(20).frame(width: 310).tint(AppPalette.accent)
            .foregroundStyle(AppPalette.ink).background(AppPalette.paper)
        }
    }

    private var customMinutes: Int? { Int(custom.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var validCustom: Bool { customMinutes.map { (1...1440).contains($0) } ?? false }
    private func startCustom() {
        guard let value = customMinutes, validCustom else { return }
        timer.start(minutes: value)
        showing = false
    }
}
