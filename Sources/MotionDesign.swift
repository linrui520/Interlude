import SwiftUI

enum LaunchPhase: Int, Comparable {
    case pending, drawing, wordmark, revealing, finished
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor
final class LaunchPresentation: ObservableObject {
    @Published private(set) var phase: LaunchPhase = .pending
    private var sequence: Task<Void, Never>?
    var isFinished: Bool { phase == .finished }

    func start(animated: Bool, intensity: Double, duration: Double = 10) {
        guard phase == .pending else { return }
        guard animated, intensity > 0, duration > 0 else { finish(); return }
        let length = min(10, max(1, duration))
        phase = .drawing
        sequence = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(length * 0.3))
                guard let self, !Task.isCancelled else { return }
                self.phase = .wordmark
                try await Task.sleep(for: .seconds(length * 0.6))
                guard !Task.isCancelled else { return }
                self.phase = .revealing
                try await Task.sleep(for: .seconds(length * 0.1))
                guard !Task.isCancelled else { return }
                self.phase = .finished
                self.sequence = nil
            } catch { /* A skipped or closed introduction never resumes. */ }
        }
    }

    func finish() {
        sequence?.cancel()
        sequence = nil
        phase = .finished
    }
}

struct InterludeRibbonShape: Shape {
    let stripe: Int
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let offset = Double(stripe) * 0.054
        var path = Path()
        path.move(to: CGPoint(x: (0.12 + offset) * s, y: 0.66 * s))
        path.addCurve(to: CGPoint(x: (0.64 + offset) * s, y: 0.34 * s),
                      control1: CGPoint(x: (0.38 + offset) * s, y: 0.72 * s),
                      control2: CGPoint(x: (0.37 + offset) * s, y: 0.28 * s))
        return path
    }
}

struct LaunchArtwork: View {
    let phase: LaunchPhase
    let intensity: Double
    var duration: Double = 10
    private var pace: Double { duration / 10 }
    private var drawn: Bool { phase >= .drawing }
    private var titled: Bool { phase >= .wordmark }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(AppPalette.accent.opacity(titled ? 0.14 : 0.04))
                    .frame(width: 150, height: 150).blur(radius: 28)
                    .scaleEffect(titled ? 1.05 : 0.85)
                    .animation(.easeInOut(duration: 3 * pace), value: titled)
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(AppPalette.ink).frame(width: 96, height: 96)
                ForEach(0..<5) { stripe in
                    InterludeRibbonShape(stripe: stripe).trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(AppPalette.paper, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 88, height: 88)
                        .animation(.easeInOut(duration: 2.4 * pace).delay(Double(stripe) * 0.15 * pace), value: drawn)
                }
            }
            .frame(width: 160, height: 130)
            .scaleEffect(drawn ? 1 : 1 - 0.08 * intensity)
            .offset(y: drawn ? 0 : 8 * intensity)
            .animation(.spring(response: 1.4 * pace, dampingFraction: 0.88), value: drawn)
            VStack(spacing: 10) {
                Text(L("间奏", "Interlude")).font(.system(size: 30, weight: .semibold)).tracking(2)
                Text("INTERLUDE").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(5)
                    .foregroundStyle(AppPalette.muted)
                Text(L("留一点空间，专注当下。", "Make room for what matters."))
                    .font(.system(size: 12)).foregroundStyle(AppPalette.muted).padding(.top, 10)
            }
            .opacity(titled ? 1 : 0).offset(y: titled ? 0 : 8 * intensity)
            .animation(.easeOut(duration: pace), value: titled)
        }
        .foregroundStyle(AppPalette.ink)
        .accessibilityElement(children: .combine)
    }
}

struct LaunchStage<Content: View>: View {
    @ObservedObject var presentation: LaunchPresentation
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder let content: () -> Content
    private var reduced: Bool { systemReduceMotion || settings.reduceMotion }
    private var revealed: Bool { presentation.phase >= .revealing || reduced }

    var body: some View {
        ZStack {
            content()
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 10 * settings.motion)
                .animation(reduced ? nil : .spring(response: max(0.3, settings.launchMode.duration / 10), dampingFraction: 0.94), value: revealed)
                .allowsHitTesting(revealed)
                .disabled(!revealed)
                .accessibilityHidden(!revealed)
            if !presentation.isFinished && !reduced {
                ZStack {
                    AppPalette.paper
                    LaunchArtwork(phase: presentation.phase, intensity: settings.motion, duration: settings.launchMode.duration)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button(L("跳过", "Skip")) { presentation.finish() }
                                .keyboardShortcut(.cancelAction)
                                .buttonStyle(.plain).font(.system(size: 12))
                                .foregroundStyle(AppPalette.muted).padding(26)
                        }
                    }
                }
                .opacity(presentation.phase >= .revealing ? 0 : 1)
                .animation(.easeOut(duration: max(0.3, settings.launchMode.duration / 10)), value: presentation.phase >= .revealing)
                .allowsHitTesting(!revealed)
                .accessibilityHidden(revealed)
                .zIndex(1)
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .onAppear {
            guard presentation.phase == .pending else { return }
            let play = !reduced && settings.shouldPlayLaunch()
            if play { settings.recordLaunch() }
            presentation.start(animated: play, intensity: settings.motion, duration: settings.launchMode.duration)
        }
        .onDisappear { presentation.finish() }
        .onChange(of: reduced) { _, reduced in if reduced { presentation.finish() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { presentation.finish() } }
    }
}

struct InterludeButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(label: configuration.label, isPressed: configuration.isPressed, scale: scale)
    }
    private struct PressFeedback<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let scale: CGFloat
        @Environment(\.motionAmount) private var amount
        @Environment(\.accessibilityReduceMotion) private var reduced
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var body: some View {
            label
                .scaleEffect(reduced || !enabled ? 1 : isPressed ? 1 - (1 - scale) * amount : hovered ? 1 + 0.008 * amount : 1)
                .opacity(isPressed && enabled ? 0.82 : 1)
                .animation(reduced || amount <= 0 ? nil : .spring(response: 0.25, dampingFraction: 0.83), value: isPressed)
                .animation(reduced || amount <= 0 ? nil : .easeOut(duration: 0.18), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

struct PageDepthModifier: ViewModifier {
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat
    func body(content: Content) -> some View { content.offset(x: x, y: y).scaleEffect(scale, anchor: .center) }
}

enum PageMotion {
    static func transition(direction: Double, amount: Double, reduced: Bool) -> AnyTransition {
        guard !reduced, amount > 0 else { return .identity }
        let incoming = AnyTransition.modifier(active: PageDepthModifier(x: direction * 24 * amount, y: 6 * amount, scale: 1 - 0.01 * amount),
                                             identity: PageDepthModifier(x: 0, y: 0, scale: 1)).combined(with: .opacity)
        let outgoing = AnyTransition.offset(x: -direction * 10 * amount).combined(with: .opacity)
            .animation(.easeOut(duration: 0.15))
        return .asymmetric(insertion: incoming, removal: outgoing)
    }
}
