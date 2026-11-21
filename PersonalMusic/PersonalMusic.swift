import SwiftUI
import AppKit

@main
struct PersonalMusicApp: App {
    @StateObject private var music = MusicModel(includeOriginals: false)

    var body: some Scene {
        Window("间奏个人音乐", id: "personal-music") {
            PersonalMusicView(model: music)
                .frame(minWidth: 700, minHeight: 540)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 800, height: 620)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入音乐…", action: music.importAudio)
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("播放") {
                Button(music.isPlaying ? "暂停" : "播放", action: music.togglePlayback)
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
    }
}

struct PersonalMusicView: View {
    @ObservedObject var model: MusicModel
    private let ink = Color(red: 0.115, green: 0.124, blue: 0.116)
    private let paper = Color(red: 0.97, green: 0.96, blue: 0.92)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("INTERLUDE / PERSONAL MUSIC")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2).foregroundStyle(.secondary)
                    Text("我的音乐").font(.system(size: 34, weight: .semibold))
                }
                Spacer()
                Text("让喜欢的旋律，陪你一会儿。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.bottom, 5)
            }
            MusicPage(model: model)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text("音乐保留在你的本地文件夹。")
                Spacer()
                Text("⌘O 导入音乐")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 23)
        .foregroundStyle(ink).background(paper)
    }
}
