import AppKit
import SwiftUI

struct AgreementDocumentView: NSViewRepresentable {
    let identity: String
    let title: String
    let paragraphs: [String]
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let clip = NSClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 23, height: 22)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel(L("协议全文", "Full agreement"))
        scroll.documentView = text
        context.coordinator.attach(scroll: scroll, text: text)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.onEnd = onEnd
        context.coordinator.show(identity: identity, title: title, paragraphs: paragraphs)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator: NSObject {
        weak var scroll: NSScrollView?
        weak var text: NSTextView?
        var onEnd: () -> Void = {}
        private var displayedID: String?
        private var ready = false

        func attach(scroll: NSScrollView, text: NSTextView) {
            self.scroll = scroll
            self.text = text
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                  name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            for event in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
                          NSWindow.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: event, object: nil)
            }
        }

        func show(identity: String, title: String, paragraphs: [String]) {
            guard displayedID != identity, let text, let scroll else { return }
            ready = false
            displayedID = identity
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 6
            paragraphStyle.paragraphSpacing = 16
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
            let body = NSMutableAttributedString(string: title + "\n\n" + paragraphs.joined(separator: "\n\n") + "\n\n" + L("— 协议全文结束 —", "— End of agreement —"), attributes: attributes)
            body.addAttribute(.font, value: NSFont.systemFont(ofSize: 18, weight: .semibold), range: NSRange(location: 0, length: (title as NSString).length))
            scroll.contentView.scroll(to: .zero)
            text.textStorage?.setAttributedString(body)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            text.sizeToFit()
            scroll.contentView.scroll(to: .zero)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayedID == identity else { return }
                self.ready = true
                self.checkEnd()
            }
        }

        @objc private func boundsChanged() {
            // Defer the callback so SwiftUI never receives state changes during an AppKit layout pass.
            DispatchQueue.main.async { [weak self] in self?.checkEnd() }
        }

        private var isReading: Bool {
            guard ready, let scroll, let window = scroll.window else { return false }
            return NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
                && !scroll.isHiddenOrHasHiddenAncestor
        }

        private func checkEnd() {
            guard isReading, let scroll, let text, let container = text.textContainer else { return }
            text.layoutManager?.ensureLayout(for: container)
            // Keyboard End reveals the final line, without scrolling through the blank bottom inset.
            let usedHeight = (text.layoutManager?.usedRect(for: container).maxY ?? .infinity) + text.textContainerOrigin.y
            let visible = scroll.contentView.bounds
            guard visible.height > 40, usedHeight.isFinite,
                  visible.minY <= usedHeight, visible.maxY >= usedHeight - 2 else { return }
            onEnd()
        }

        func stop() {
            ready = false
            NotificationCenter.default.removeObserver(self)
        }
    }
}

struct AppAgreementReader: View {
    @ObservedObject var model: AppAgreementModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "doc.text")
                    .font(.system(size: 29, weight: .light)).foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("欢迎使用间奏", "Welcome to Interlude")).font(.system(size: 27, weight: .semibold))
                    Text(L("隐私政策与使用协议", "Privacy Policy & Terms of Use"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            AgreementDocumentView(identity: "required-" + AppAgreementDocument.version + "-" + AppLanguage.current.rawValue,
                                  title: AppAgreementDocument.title,
                                  paragraphs: AppAgreementDocument.sections.flatMap { [$0.title] + $0.paragraphs },
                                  onEnd: { model.markEndVisible() })
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 13))
                .clipShape(RoundedRectangle(cornerRadius: 13))
            Text(model.hasReachedEnd
                 ? L("已到达协议末尾，可以勾选同意。", "You have reached the end. You can now confirm your agreement.")
                 : L("请阅读全文，滚动到底部后勾选同意。", "Please review the agreement and scroll to the bottom to continue."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle(L("我已阅读并同意《隐私政策与使用协议》", "I have read and agree to the Privacy Policy & Terms of Use"), isOn: $model.checked)
                .toggleStyle(.checkbox).disabled(!model.readComplete).font(.system(size: 13))
            HStack {
                Button(L("不同意并退出", "Decline & quit")) { NSApp.terminate(nil) }
                Spacer()
                Button(L("同意并进入间奏", "Agree & open Interlude")) { model.accept() }
                    .buttonStyle(.borderedProminent).tint(AppPalette.accent)
                    .disabled(!model.canAccept).keyboardShortcut(.defaultAction)
            }
        }
        .padding(34).padding(.top, 18)
        .frame(minWidth: 940, minHeight: 620)
        .foregroundStyle(AppPalette.ink).background(AppPalette.paper)
    }
}

struct AppAgreementReview: View {
    @ObservedObject var model: AppAgreementModel
    let close: () -> Void
    let revoke: () -> Void
    @State private var confirmingWithdrawal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppAgreementDocument.title).font(.system(size: 25, weight: .semibold))
            Text(L("当前说明：", "Current policy: ") + AppAgreementDocument.version)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let acceptedAt = model.acceptedAt {
                Text(L("本机确认时间：", "Confirmed on this Mac: ") + acceptedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            AgreementDocumentView(identity: "review-" + AppAgreementDocument.version + AppLanguage.current.rawValue,
                                  title: AppAgreementDocument.title,
                                  paragraphs: AppAgreementDocument.sections.flatMap { [$0.title] + $0.paragraphs })
                .frame(height: 360)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button(L("撤回同意并停用", "Withdraw consent & stop")) { confirmingWithdrawal = true }
                Spacer()
                Button(L("完成", "Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 720)
        .foregroundStyle(AppPalette.ink).background(AppPalette.paper)
        .alert(L("撤回同意并停用间奏？", "Withdraw consent and stop Interlude?"), isPresented: $confirmingWithdrawal) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("撤回并停用", "Withdraw & stop"), role: .destructive, action: revoke)
        } message: {
            Text(L("专注计时和音乐将暂停，已有待办和曲库保留。再次使用需要重新阅读并同意本协议。", "Focus and music will pause. Saved tasks and music libraries are kept. You will need to review and accept the agreement to use Interlude again."))
        }
    }
}
