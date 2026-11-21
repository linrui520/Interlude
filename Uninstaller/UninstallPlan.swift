import Foundation

private let prefersEnglish: Bool = {
    let language = UserDefaults(suiteName: "com.interlude.desktop")?.string(forKey: "interlude.settings.language")
    switch language {
    case "en": return true
    case "zh-Hans": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("zh") != true
    }
}()

func UL(_ chinese: String, _ english: String) -> String {
    prefersEnglish ? english : chinese
}

/// Creates the administrator operation. The caller handles personal files as the logged-in user.
struct UninstallPlan {
    let removeComponents: Bool
    let removePersonalPlayer: Bool
    let removeUninstaller: Bool

    init(removeComponents: Bool, removePersonalPlayer: Bool, removeUninstaller: Bool = true) {
        self.removeComponents = removeComponents
        self.removePersonalPlayer = removePersonalPlayer
        self.removeUninstaller = removeUninstaller
    }

    /// All privileged paths and commands are constants. Only boolean choices cross into the script.
    func privilegedShell() -> String {
        #"""
        set -eu
        applications=/Applications
        library=/Library
        support="$library/Application Support"
        components="$support/Interlude"
        main_app="$applications/间奏.app"
        player_app="$applications/间奏个人音乐.app"
        uninstall_app="$applications/卸载间奏.app"
        remove_components=\#(removeComponents ? 1 : 0)
        remove_player=\#(removePersonalPlayer ? 1 : 0)
        remove_uninstaller=\#(removeUninstaller ? 1 : 0)

        fail() { printf '%s\n' "$*" >&2; exit 1; }

        check_directory() {
            [ ! -L "$1" ] || fail "\#(UL("路径是符号链接，请检查后重试：$1", "Symbolic link found. Check the path and retry: $1"))"
            [ ! -e "$1" ] || [ -d "$1" ] || fail "\#(UL("需要文件夹，请检查后重试：$1", "Expected a folder. Check the path and retry: $1"))"
        }

        check_file() {
            [ ! -L "$1" ] || fail "\#(UL("路径是符号链接，请检查后重试：$1", "Symbolic link found. Check the path and retry: $1"))"
            [ ! -e "$1" ] || [ -f "$1" ] || fail "\#(UL("需要常规文件，请检查后重试：$1", "Expected a regular file. Check the path and retry: $1"))"
        }

        check_app() {
            check_directory "$1"
            [ -d "$1" ] || return 0
            check_directory "$1/Contents"
            check_file "$1/Contents/Info.plist"
            bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist") ||
                fail "\#(UL("无法读取应用身份，请检查：$1", "Could not read the application identity: $1"))"
            [ "$bundle_id" = "$2" ] || fail "\#(UL("应用身份不符，已保留：$1", "Application identity mismatch. Preserved: $1"))"
        }

        remove_empty_directory() {
            [ -d "$1" ] || return 0
            entry=$(/usr/bin/find "$1" -mindepth 1 -maxdepth 1 -print -quit) ||
                fail "\#(UL("无法检查目录：$1", "Could not inspect folder: $1"))"
            if [ -z "$entry" ]; then
                /bin/rmdir "$1" || fail "\#(UL("无法移除空目录，请检查权限后重试：$1", "Could not remove empty folder. Check permissions and retry: $1"))"
            fi
        }

        forget_if_installed() {
            if printf '%s\n' "$receipts" | /usr/bin/grep -Fxq "$1"; then
                /usr/sbin/pkgutil --forget "$1" >/dev/null ||
                    fail "\#(UL("无法清理安装记录，请重试：$1", "Could not clear installation receipt. Retry: $1"))"
            fi
        }

        check_stopped() {
            if /usr/bin/pgrep "$1" "$2" >/dev/null; then
                fail "\#(UL("请先退出正在运行的$3，再重试卸载。", "Quit the running app ($3) before retrying."))"
            else
                [ "$?" = 1 ] || fail "\#(UL("无法确认$3已退出，请重试。", "Could not verify that $3 quit. Please try again."))"
            fi
        }

        check_directory "$applications"
        check_stopped -x Interlude 间奏
        check_app "$main_app" com.interlude.desktop
        if [ "$remove_player" = 1 ]; then
            check_stopped -f '^/Applications/间奏个人音乐[.]app/Contents/MacOS/InterludePersonalMusic([[:space:]]|$)' 间奏个人音乐
            check_app "$player_app" com.interlude.personal-music
        fi
        if [ "$remove_uninstaller" = 1 ]; then
            check_app "$uninstall_app" com.interlude.uninstaller
        fi

        if [ "$remove_components" = 1 ]; then
            check_directory "$library"
            check_directory "$support"
            check_directory "$components"
            check_directory "$components/Source"
            check_directory "$components/Music"
            check_directory "$components/Documents"
            for name in Stillroom.m4a Daylight.m4a Nocturne.m4a LICENSE.txt; do
                check_file "$components/Music/$name"
            done
            for name in LICENSE.txt 使用说明.txt "User Guide.txt" 隐私政策与使用协议.txt "Privacy Policy and Terms of Use.txt"; do
                check_file "$components/Documents/$name"
            done
        fi

        receipts=$(/usr/sbin/pkgutil --pkgs) || fail "\#(UL("无法读取安装记录，请重试。", "Could not read package receipts. Please try again."))"
        /bin/rm -rfx "$main_app" || fail "\#(UL("无法移除主程序，请检查权限后重试。", "Could not remove Interlude. Check permissions and retry."))"
        if [ "$remove_player" = 1 ]; then
            /bin/rm -rfx "$player_app" || fail "\#(UL("无法移除个人音乐播放器，请检查权限后重试。", "Could not remove the legacy Personal Music player. Check permissions and retry."))"
            forget_if_installed com.interlude.pkg.personal-music
        fi

        if [ "$remove_components" = 1 ]; then
            /bin/rm -rfx "$components/Source" || fail "\#(UL("无法移除源码文件夹，请检查权限后重试。", "Could not remove the source folder. Check permissions and retry."))"
            for name in Stillroom.m4a Daylight.m4a Nocturne.m4a LICENSE.txt; do
                /bin/rm -f "$components/Music/$name" || fail "\#(UL("无法移除音乐组件：$name", "Could not remove audio component: $name"))"
            done
            for name in LICENSE.txt 使用说明.txt "User Guide.txt" 隐私政策与使用协议.txt "Privacy Policy and Terms of Use.txt"; do
                /bin/rm -f "$components/Documents/$name" || fail "\#(UL("无法移除已安装的说明文件，请检查权限后重试。", "Could not remove installed documentation. Check permissions and retry."))"
            done
            remove_empty_directory "$components/Music"
            remove_empty_directory "$components/Documents"
            remove_empty_directory "$components"
            forget_if_installed com.interlude.pkg.music
            forget_if_installed com.interlude.pkg.source
        fi
        forget_if_installed com.interlude.pkg.core
        if [ "$remove_uninstaller" = 1 ]; then
            /bin/rm -rfx "$uninstall_app" || fail "\#(UL("无法移除卸载工具，请检查权限后重试。", "Could not remove the uninstaller. Check permissions and retry."))"
        fi
        """#
    }
}
