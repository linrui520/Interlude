import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: Self { self }
    static var current: Self {
        let choice = Self(rawValue: UserDefaults.standard.string(forKey: "interlude.settings.language") ?? "system") ?? .system
        if choice != .system { return choice }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
    var title: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

func L(_ chinese: String, _ english: String) -> String {
    AppLanguage.current == .english ? english : chinese
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case ember, forest, ocean
    var id: Self { self }
    var title: String {
        switch self {
        case .ember: return L("暖橙", "Ember")
        case .forest: return L("森林", "Forest")
        case .ocean: return L("海蓝", "Ocean")
        }
    }
}

enum AppPalette {
    static var increasedContrast: Bool { UserDefaults.standard.bool(forKey: "interlude.settings.highContrast") || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static var ink: Color { adaptive(NSColor(white: increasedContrast ? 0.02 : 0.13, alpha: 1), NSColor(white: increasedContrast ? 1 : 0.94, alpha: 1)) }
    static var paper: Color { adaptive(NSColor(red: 0.965, green: 0.961, blue: 0.941, alpha: 1), NSColor(red: 0.075, green: 0.085, blue: 0.08, alpha: 1)) }
    static var side: Color { adaptive(NSColor(red: 0.932, green: 0.928, blue: 0.902, alpha: 1), NSColor(red: 0.10, green: 0.11, blue: 0.10, alpha: 1)) }
    static var card: Color { adaptive(NSColor(red: 0.99, green: 0.985, blue: 0.97, alpha: 1), NSColor(red: 0.14, green: 0.15, blue: 0.14, alpha: 1)) }
    static var muted: Color { adaptive(NSColor(white: increasedContrast ? 0.25 : 0.40, alpha: 1), NSColor(white: increasedContrast ? 0.84 : 0.65, alpha: 1)) }
    static var line: Color { adaptive(NSColor.black.withAlphaComponent(increasedContrast ? 0.44 : 0.13), NSColor.white.withAlphaComponent(increasedContrast ? 0.5 : 0.15)) }
    static var accent: Color {
        if increasedContrast {
            switch AppTheme(rawValue: UserDefaults.standard.string(forKey: "interlude.settings.theme") ?? "ember") ?? .ember {
            case .ember: return adaptive(NSColor(red: 0.57, green: 0.20, blue: 0.07, alpha: 1), NSColor(red: 1, green: 0.7, blue: 0.49, alpha: 1))
            case .forest: return adaptive(NSColor(red: 0.10, green: 0.37, blue: 0.19, alpha: 1), NSColor(red: 0.51, green: 0.88, blue: 0.62, alpha: 1))
            case .ocean: return adaptive(NSColor(red: 0.08, green: 0.30, blue: 0.59, alpha: 1), NSColor(red: 0.55, green: 0.78, blue: 1, alpha: 1))
            }
        }
        switch AppTheme(rawValue: UserDefaults.standard.string(forKey: "interlude.settings.theme") ?? "ember") ?? .ember {
        case .ember: return Color(red: 0.92, green: 0.38, blue: 0.20)
        case .forest: return Color(red: 0.32, green: 0.65, blue: 0.44)
        case .ocean: return Color(red: 0.25, green: 0.56, blue: 0.88)
        }
    }
}

enum LaunchAnimationMode: String, CaseIterable, Identifiable {
    case full, short, off
    var id: Self { self }
    var duration: Double { self == .full ? 10 : self == .short ? 3 : 0 }
    var title: String {
        switch self {
        case .full: return L("完整版 · 10 秒", "Full · 10 seconds")
        case .short: return L("简短版 · 3 秒", "Short · 3 seconds")
        case .off: return L("关闭", "Off")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var language: AppLanguage { didSet { save(language.rawValue, "language") } }
    @Published var appearance: AppAppearance { didSet { save(appearance.rawValue, "appearance") } }
    @Published var theme: AppTheme { didSet { save(theme.rawValue, "theme") } }
    @Published var motion: Double { didSet { save(motion, "motion") } }
    @Published var phaseSound: String { didSet { save(phaseSound, "phaseSound") } }
    @Published var soundVolume: Double { didSet { save(soundVolume, "soundVolume") } }
    @Published var musicFade: Bool { didSet { save(musicFade, "musicFade") } }
    @Published var shortcut: String { didSet { save(shortcut, "shortcut") } }
    @Published var launchMode: LaunchAnimationMode { didSet { save(launchMode.rawValue, "launchMode") } }
    @Published var launchOncePerDay: Bool { didSet { save(launchOncePerDay, "launchOncePerDay") } }
    @Published var highContrast: Bool { didSet { save(highContrast, "highContrast") } }
    @Published var interfaceScale: Double { didSet { save(interfaceScale, "interfaceScale") } }
    private let defaults: UserDefaults
    private var previewSound: NSSound?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        highContrast = defaults.bool(forKey: "interlude.settings.highContrast")
        let savedScale = defaults.double(forKey: "interlude.settings.interfaceScale")
        interfaceScale = [1.0, 1.1, 1.2].contains(savedScale) ? savedScale : 1.0
        launchMode = LaunchAnimationMode(rawValue: defaults.string(forKey: "interlude.settings.launchMode") ?? "full") ?? .full
        launchOncePerDay = defaults.bool(forKey: "interlude.settings.launchOncePerDay")
        language = AppLanguage(rawValue: defaults.string(forKey: "interlude.settings.language") ?? "system") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: "interlude.settings.appearance") ?? "system") ?? .system
        theme = AppTheme(rawValue: defaults.string(forKey: "interlude.settings.theme") ?? "ember") ?? .ember
        motion = defaults.object(forKey: "interlude.settings.motion") == nil ? 1 : min(1, max(0, defaults.double(forKey: "interlude.settings.motion")))
        phaseSound = defaults.string(forKey: "interlude.settings.phaseSound") ?? "Glass"
        soundVolume = defaults.object(forKey: "interlude.settings.soundVolume") == nil ? 0.7 : min(1, max(0, defaults.double(forKey: "interlude.settings.soundVolume")))
        musicFade = defaults.object(forKey: "interlude.settings.musicFade") == nil ? true : defaults.bool(forKey: "interlude.settings.musicFade")
        shortcut = defaults.string(forKey: "interlude.settings.shortcut") ?? "commandShiftSpace"
    }

    func shouldPlayLaunch(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard launchMode != .off else { return false }
        guard launchOncePerDay, let previous = defaults.object(forKey: "interlude.settings.launchLastPlayedAt") as? Date else { return true }
        return !calendar.isDate(previous, inSameDayAs: date)
    }

    func recordLaunch(at date: Date = Date()) {
        defaults.set(date, forKey: "interlude.settings.launchLastPlayedAt")
    }

    func reload() {
        let saved = AppSettings(defaults: defaults)
        language = saved.language; appearance = saved.appearance; theme = saved.theme
        motion = saved.motion; phaseSound = saved.phaseSound; soundVolume = saved.soundVolume
        musicFade = saved.musicFade; shortcut = saved.shortcut
        launchMode = saved.launchMode; launchOncePerDay = saved.launchOncePerDay
        highContrast = saved.highContrast; interfaceScale = saved.interfaceScale
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: "interlude.settings." + key) }
    var locale: Locale { Locale(identifier: AppLanguage.current == .english ? "en" : "zh_Hans") }
    var reduceMotion: Bool { motion < 0.01 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var visualIdentity: String { language.rawValue + appearance.rawValue + theme.rawValue + String(highContrast) }

    func stopPhaseSound() { previewSound?.stop(); previewSound = nil }

    func playPhaseSound() {
        previewSound?.stop()
        guard phaseSound != "none", soundVolume > 0, let sound = NSSound(named: NSSound.Name(phaseSound)) else { return }
        sound.volume = Float(soundVolume)
        previewSound = sound
        sound.play()
    }
}

private struct MotionAmountKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var motionAmount: Double {
        get { self[MotionAmountKey.self] }
        set { self[MotionAmountKey.self] = newValue }
    }
}
