import SwiftUI

enum MusicSection: String, CaseIterable, Identifiable {
    case ambient = "环境音乐"
    case personal = "个人音乐"
    var id: Self { self }
    var displayTitle: String { self == .ambient ? L("环境音乐", "Ambient Music") : L("个人音乐", "Personal Music") }
}

@MainActor
final class MusicWorkspaceModel: ObservableObject {
    static let privacyVersion = 1
    static let consentKey = "interlude.personalMusic.privacyVersion"
    static let consentDateKey = "interlude.personalMusic.privacyAcceptedAt"

    @Published private(set) var section: MusicSection = .ambient
    @Published private(set) var hasConsent: Bool
    @Published var showingPrivacy = false
    let ambient: MusicModel
    let personal: MusicModel
    let mixer: NoiseMixer
    let sleepTimer = MusicSleepTimer()
    private let settings: UserDefaults
    private let legacyPersonalSettings: UserDefaults?

    init(settings: UserDefaults = .standard,
         legacyPersonalSettings: UserDefaults? = UserDefaults(suiteName: "com.interlude.personal-music")) {
        self.settings = settings
        self.legacyPersonalSettings = legacyPersonalSettings
        hasConsent = settings.integer(forKey: Self.consentKey) == Self.privacyVersion
        mixer = NoiseMixer(settings: settings)
        ambient = MusicModel(settings: settings, allowsImport: false)
        personal = MusicModel(includeOriginals: false, settings: settings,
                              preferencePrefix: "interlude.personalMusic", requiresConsent: true)
        sleepTimer.onFinish = { [weak self] in
            self?.ambient.fadeForSleep()
            self?.personal.fadeForSleep()
            self?.mixer.fadeOutAll()
        }
    }

    var sceneMusicID: String? { ambient.playingOriginalID }

    func applySceneMusic(_ id: String) {
        if id == "none" {
            ambient.pausePlayback()
            personal.pausePlayback()
        } else if ambient.chooseOriginal(id) {
            personal.pausePlayback()
            section = .ambient
        }
    }

    func focusDidFinish() { sleepTimer.focusDidFinish() }

    func stopAll() {
        sleepTimer.cancel()
        mixer.stopAll()
        ambient.releaseAudio()
        personal.setPersonalAccess(false)
        section = .ambient
    }

    var activePlayer: MusicModel { section == .personal ? personal : ambient }

    func requestSection(_ requested: MusicSection) {
        if requested == .personal {
            guard hasConsent else { showingPrivacy = true; return }
            openPersonalMusic()
        } else {
            personal.pausePlayback()
            section = .ambient
        }
    }

    func acceptPersonalUse(checked: Bool) {
        guard checked else { return }
        settings.set(Self.privacyVersion, forKey: Self.consentKey)
        settings.set(Date(), forKey: Self.consentDateKey)
        hasConsent = true
        openPersonalMusic()
        showingPrivacy = false
    }

    func revokePersonalUse() {
        personal.setPersonalAccess(false)
        settings.removeObject(forKey: Self.consentKey)
        settings.removeObject(forKey: Self.consentDateKey)
        hasConsent = false
        section = .ambient
        showingPrivacy = false
    }

    private func openPersonalMusic() {
        ambient.pausePlayback()
        personal.setPersonalAccess(true)
        personal.migrateLegacyImports(from: [settings] + [legacyPersonalSettings].compactMap { $0 })
        section = .personal
    }
}

struct MusicWorkspacePage: View {
    @ObservedObject var library: MusicWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @Environment(\.motionAmount) private var motionAmount
    @Namespace private var selectedTab

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    ForEach(MusicSection.allCases) { section in
                        Button { library.requestSection(section) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: section == .personal ? "person.crop.square" : "waveform")
                                Text(section.displayTitle)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 15).frame(height: 34)
                            .foregroundStyle(library.section == section ? AppPalette.paper : AppPalette.ink)
                            .background {
                                if library.section == section {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(AppPalette.ink)
                                        .matchedGeometryEffect(id: "music-section", in: selectedTab)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(InterludeButtonStyle(scale: 0.98))
                        .accessibilityAddTraits(library.section == section ? .isSelected : [])
                    }
                }
                .padding(4)
                .background(AppPalette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                SoundscapeButton(mixer: library.mixer)
                MusicSleepButton(timer: library.sleepTimer)
                Button { library.showingPrivacy = true } label: {
                    Label(L("隐私说明", "Privacy"), systemImage: "hand.raised")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(AppPalette.muted)
            }
            ZStack(alignment: .topLeading) {
                if library.section == .personal, library.hasConsent {
                    MusicPage(model: library.personal)
                        .transition(.asymmetric(insertion: sectionTransition(1), removal: .identity))
                } else {
                    MusicPage(model: library.ambient)
                        .transition(sectionTransition(-1))
                }
            }
        }
        .animation(reduceMotion || !library.hasConsent ? nil : .spring(response: 0.39, dampingFraction: 0.91), value: library.section)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .sheet(isPresented: $library.showingPrivacy) {
            PersonalMusicPrivacySheet(library: library)
        }
    }

    private func sectionTransition(_ direction: Double) -> AnyTransition {
        PageMotion.transition(direction: direction, amount: motionAmount * 0.65,
                              reduced: reduceMotion || !library.hasConsent)
    }
}

struct PersonalMusicPrivacySheet: View {
    @ObservedObject var library: MusicWorkspaceModel
    @State private var checked = false
    private var ink: Color { AppPalette.ink }
    private var accent: Color { AppPalette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "hand.raised.square")
                    .font(.system(size: 29, weight: .light)).foregroundStyle(accent)
                    .frame(width: 56, height: 56)
                    .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("个人音乐隐私说明", "Personal Music Privacy")).font(.system(size: 24, weight: .semibold))
                    Text(L("先了解数据如何使用，再开始聆听。", "How your audio files and playlists are used."))
                        .font(.system(size: 12)).foregroundStyle(AppPalette.muted)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detail(L("只读取你选择的音乐", "Files you choose"),
                           L("间奏读取你选择或拖入的音频文件，以获取时长并播放音乐。应用不会扫描其他文件夹，也不要求注册账号。",
                             "Interlude reads the audio files you choose or drop here to determine their duration and play them. It does not scan other folders or require an account."))
                    detail(L("曲库与歌单保存在本机", "Your library and playlists stay on this Mac"),
                           L("曲名、文件位置、时长、歌单名称及曲目顺序、音量、随机和循环播放偏好、淡入淡出设置及同意记录保存在当前用户的本机设置中。",
                             "Local settings store track names, file paths, durations, playlist names and track order, volume, shuffle, repeat and fade preferences, and your consent record."))
                    detail(L("没有上传或跟踪", "No uploads or tracking"),
                           L("个人音乐功能不向服务器发送音频、文件路径或歌单，也不包含广告追踪和使用统计。原文件留在你选择的位置。",
                             "Personal Music sends no audio, paths, or playlists to a server and includes no advertising trackers or usage analytics. Files stay where you keep them."))
                    detail(L("你可以随时停用", "Withdraw at any time"),
                           L("在此撤回同意后，个人音乐会立即停止并锁定。曲库和歌单默认保留，再次同意后可继续使用。从曲库移除歌曲或删除歌单不会删除音频文件。",
                             "Withdrawing consent here immediately stops playback and locks Personal Music. Your library and playlists remain on this Mac until you choose to use them again. Removing a track or deleting a playlist leaves the audio file in place."))
                    Text(L("升级用户：同意后，旧版已导入的本地曲目可迁移至个人音乐库。迁移仅读取本机曲库记录。",
                           "When upgrading, consenting allows previously imported tracks to migrate into Personal Music using the local library records."))
                        .font(.system(size: 11)).foregroundStyle(AppPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .frame(height: 265)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12))

            if library.hasConsent {
                Label(L("你已同意当前版本的隐私说明", "You have accepted this privacy notice."), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(AppPalette.muted)
                HStack {
                    Button(L("撤回同意", "Withdraw Consent")) {
                        var immediate = Transaction(animation: nil)
                        immediate.disablesAnimations = true
                        withTransaction(immediate) { library.revokePersonalUse() }
                    }
                    Spacer()
                    Button(L("完成", "Done")) { library.showingPrivacy = false }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Toggle(L("我已阅读并同意《个人音乐隐私说明》", "I have read and agree to the Personal Music Privacy Notice."), isOn: $checked)
                    .toggleStyle(.checkbox).font(.system(size: 13))
                HStack {
                    Text(L("未同意时，个人音乐保持关闭。", "Personal Music stays locked until you agree."))
                        .font(.system(size: 11)).foregroundStyle(AppPalette.muted)
                    Spacer()
                    Button(L("暂不使用", "Not Now")) { library.showingPrivacy = false }
                        .keyboardShortcut(.cancelAction)
                    Button(L("同意并开始使用", "Agree and Continue")) { library.acceptPersonalUse(checked: checked) }
                        .buttonStyle(.borderedProminent).tint(accent)
                        .keyboardShortcut(.defaultAction).disabled(!checked)
                }
            }
        }
        .padding(28).frame(width: 590)
        .foregroundStyle(ink)
        .background(AppPalette.paper)
    }

    private func detail(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(body).font(.system(size: 12)).foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }
}
