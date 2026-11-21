import Foundation
import Combine

@MainActor
final class AppAgreementModel: ObservableObject {
    private struct Checkpoint: Codable {
        let version: String
        let reachedEnd: Bool
    }

    static let versionKey = "interlude.appAgreement.acceptedVersion"
    static let dateKey = "interlude.appAgreement.acceptedAt"
    static let progressKey = "interlude.appAgreement.readingProgress"

    @Published private(set) var hasAccepted = false
    @Published private(set) var acceptedAt: Date?
    @Published private(set) var acceptedVersion: String?
    @Published private(set) var hasReachedEnd = false
    @Published var checked = false {
        didSet { if checked && !readComplete { checked = false } }
    }

    private let settings: UserDefaults

    var readComplete: Bool {
        hasAccepted || hasReachedEnd
    }
    var canAccept: Bool { !hasAccepted && readComplete && checked }

    init(settings: UserDefaults = .standard) {
        self.settings = settings
        precondition(!AppAgreementDocument.sections.isEmpty, "The app agreement must include at least one section.")
        if let version = settings.string(forKey: Self.versionKey), Self.isCompatible(version),
           let date = settings.object(forKey: Self.dateKey) as? Date, date.timeIntervalSince1970.isFinite {
            acceptedVersion = version
            acceptedAt = date
            hasAccepted = true
            return
        }
        if let data = settings.data(forKey: Self.progressKey),
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: data),
           Self.isCompatible(saved.version) {
            hasReachedEnd = saved.reachedEnd
        }
    }

    private static func isCompatible(_ version: String) -> Bool {
        version == AppAgreementDocument.version
    }

    func markEndVisible() {
        guard !hasAccepted, !hasReachedEnd else { return }
        hasReachedEnd = true
        saveProgress()
    }

    func accept() {
        guard canAccept else { return }
        let now = Date()
        settings.set(now, forKey: Self.dateKey)
        settings.set(AppAgreementDocument.version, forKey: Self.versionKey)
        settings.removeObject(forKey: Self.progressKey)
        acceptedAt = now
        acceptedVersion = AppAgreementDocument.version
        hasAccepted = true
    }

    func revoke() {
        settings.removeObject(forKey: Self.versionKey)
        settings.removeObject(forKey: Self.dateKey)
        settings.removeObject(forKey: Self.progressKey)
        checked = false
        hasReachedEnd = false
        acceptedAt = nil
        acceptedVersion = nil
        hasAccepted = false
    }

    private func saveProgress() {
        let checkpoint = Checkpoint(version: AppAgreementDocument.version, reachedEnd: hasReachedEnd)
        if let data = try? JSONEncoder().encode(checkpoint) { settings.set(data, forKey: Self.progressKey) }
    }
}
