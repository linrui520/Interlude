import Foundation
import SwiftUI

struct TaskSubtask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var completed: Bool
}

struct InterludeTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var completed: Bool
    var subtasks: [TaskSubtask]
    var plannedRounds: Int?

    init(id: UUID, title: String, completed: Bool, subtasks: [TaskSubtask] = [], plannedRounds: Int? = nil) {
        self.id = id
        self.title = title
        self.completed = completed
        self.subtasks = subtasks
        self.plannedRounds = plannedRounds
    }

    private enum CodingKeys: String, CodingKey { case id, title, completed, subtasks, plannedRounds }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        completed = try values.decode(Bool.self, forKey: .completed)
        subtasks = try values.decodeIfPresent([TaskSubtask].self, forKey: .subtasks) ?? []
        plannedRounds = try values.decodeIfPresent(Int.self, forKey: .plannedRounds)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(completed, forKey: .completed)
        if !subtasks.isEmpty { try values.encode(subtasks, forKey: .subtasks) }
        try values.encodeIfPresent(plannedRounds, forKey: .plannedRounds)
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var items: [InterludeTask] = []
    @Published private(set) var deleted: InterludeTask?
    @Published private var storageIssue: StorageIssue?
    private enum StorageIssue { case read, write }
    var storageError: String? {
        switch storageIssue {
        case .read: return L("无法读取已保存的清单，请检查文件访问权限后重试。", "Could not read your tasks. Check file permissions and try again.")
        case .write: return L("清单未能保存，请检查本机存储空间和文件访问权限。", "Could not save your tasks. Check disk space and file permissions.")
        case nil: return nil
        }
    }

    @Published fileprivate var newTitle = ""
    @Published fileprivate var filter = TaskFilter.all
    @Published fileprivate var editingID: UUID?
    @Published fileprivate var renameDraft = ""
    @Published fileprivate var expandedID: UUID?

    static let maximumDataBytes = 32 * 1024 * 1024
    static let maximumTasks = 100_000
    static let maximumSubtasks = 200
    static let maximumTitleBytes = 65_536
    static let maximumPlannedRounds = 99

    static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        title.utf8.count <= maximumTitleBytes && !title.utf8.contains(0)
    }

    /// Accepts legacy tasks while strictly checking the extended backup schema.
    static func validateBackupItems(_ data: Data) throws -> [InterludeTask] {
        guard data.count <= maximumDataBytes,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= maximumTasks else { throw CocoaError(.fileReadCorruptFile) }
        for row in rows {
            guard Set(row.keys).isSubset(of: ["id", "title", "completed", "subtasks", "plannedRounds"]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let value = row["subtasks"], !(value is NSNull) {
                guard let subtasks = value as? [[String: Any]], subtasks.count <= maximumSubtasks,
                      subtasks.allSatisfy({ Set($0.keys) == ["id", "title", "completed"] }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        let tasks = try JSONDecoder().decode([InterludeTask].self, from: data)
        try validateItems(tasks)
        return tasks
    }

    private static func validateItems(_ tasks: [InterludeTask]) throws {
        guard tasks.count <= maximumTasks else { throw CocoaError(.fileReadCorruptFile) }
        var ids = Set<UUID>()
        var subtaskCount = 0
        for task in tasks {
            guard ids.insert(task.id).inserted, validTitle(task.title), task.subtasks.count <= maximumSubtasks,
                  task.plannedRounds.map({ (1...maximumPlannedRounds).contains($0) }) ?? true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            subtaskCount += task.subtasks.count
            guard subtaskCount <= 100_000 else { throw CocoaError(.fileReadCorruptFile) }
            for subtask in task.subtasks {
                guard ids.insert(subtask.id).inserted, validTitle(subtask.title) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }

    private let file: URL
    private var deletedIndex = 0
    private var loadFailed = false

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Interlude", isDirectory: true)
            .appendingPathComponent("tasks.json")
        load()
    }

    var pendingCount: Int { items.filter { !$0.completed }.count }
    var completedCount: Int { items.count - pendingCount }

    func load() {
        do {
            items = try Self.validateBackupItems(Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            items = []
        } catch {
            storageIssue = .read
            loadFailed = true
            return
        }
        storageIssue = nil
        loadFailed = false
    }

    @discardableResult
    func add(_ input: String) -> Bool {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validTitle(title), items.count < Self.maximumTasks else { return false }
        return save([InterludeTask(id: UUID(), title: title, completed: false)] + items)
    }

    @discardableResult
    func rename(_ id: UUID, to input: String) -> Bool {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validTitle(title), let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var updated = items
        updated[index].title = title
        return save(updated)
    }

    @discardableResult
    func setPlannedRounds(_ id: UUID, to rounds: Int?) -> Bool {
        guard rounds.map({ (1...Self.maximumPlannedRounds).contains($0) }) ?? true,
              let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var updated = items
        updated[index].plannedRounds = rounds
        return save(updated)
    }

    @discardableResult
    func addSubtask(to taskID: UUID, title input: String) -> Bool {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validTitle(title), let index = items.firstIndex(where: { $0.id == taskID }),
              items[index].subtasks.count < Self.maximumSubtasks else { return false }
        var updated = items
        updated[index].subtasks.append(TaskSubtask(id: UUID(), title: title, completed: false))
        return save(updated)
    }

    @discardableResult
    func renameSubtask(_ subtaskID: UUID, in taskID: UUID, to input: String) -> Bool {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validTitle(title), let index = items.firstIndex(where: { $0.id == taskID }),
              let subindex = items[index].subtasks.firstIndex(where: { $0.id == subtaskID }) else { return false }
        var updated = items
        updated[index].subtasks[subindex].title = title
        return save(updated)
    }

    @discardableResult
    func toggleSubtask(_ subtaskID: UUID, in taskID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == taskID }),
              let subindex = items[index].subtasks.firstIndex(where: { $0.id == subtaskID }) else { return false }
        var updated = items
        updated[index].subtasks[subindex].completed.toggle()
        return save(updated)
    }

    @discardableResult
    func removeSubtask(_ subtaskID: UUID, from taskID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == taskID }),
              let subindex = items[index].subtasks.firstIndex(where: { $0.id == subtaskID }) else { return false }
        var updated = items
        updated[index].subtasks.remove(at: subindex)
        return save(updated)
    }

    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].completed.toggle()
        _ = save(updated)
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        let removed = updated.remove(at: index)
        if save(updated) {
            deletedIndex = index
            deleted = removed
            if expandedID == id { expandedID = nil }
            if editingID == id { editingID = nil }
        }
    }

    func undoRemoval() {
        guard let deleted else { return }
        var updated = items
        updated.insert(deleted, at: min(deletedIndex, updated.count))
        if save(updated) { self.deleted = nil }
    }

    func dismissUndo() { deleted = nil }

    func itemsForBackup() throws -> [InterludeTask] {
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        try Self.validateItems(items)
        return items
    }

    func restoreBackupItems(_ restored: [InterludeTask]) throws {
        try Self.validateItems(restored)
        let data = try JSONEncoder().encode(restored)
        guard data.count <= Self.maximumDataBytes else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        items = restored
        storageIssue = nil
        loadFailed = false
        deleted = nil
        editingID = nil
        expandedID = nil
    }

    private func save(_ updated: [InterludeTask]) -> Bool {
        guard !loadFailed else { return false }
        do {
            try Self.validateItems(updated)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            guard data.count <= Self.maximumDataBytes else { throw CocoaError(.fileReadCorruptFile) }
            try data.write(to: file, options: .atomic)
            items = updated
            storageIssue = nil
            return true
        } catch {
            storageIssue = .write
            return false
        }
    }
}

fileprivate enum TaskFilter: CaseIterable {
    case all, open, done
    var title: String {
        switch self {
        case .all: return L("全部", "All")
        case .open: return L("待完成", "To do")
        case .done: return L("已完成", "Done")
        }
    }
}

private struct TaskPaper: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule().fill(AppPalette.accent).frame(width: 21, height: 3)
            ForEach(0..<3) { i in
                HStack(spacing: 6) {
                    Circle().stroke(AppPalette.muted.opacity(0.65), lineWidth: 1).frame(width: 6, height: 6)
                    Capsule().fill(AppPalette.muted.opacity(0.32))
                        .frame(width: i == 1 ? 41 : 30, height: 1.5)
                }
            }
        }
        .padding(12)
        .frame(width: 82, height: 75)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppPalette.line))
    }
}

private struct EmptyTasks: View {
    let filter: TaskFilter
    let emptyLibrary: Bool
    let addTask: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.88, green: 0.86, blue: 0.79))
                    .frame(width: 82, height: 74).rotationEffect(.degrees(-14)).offset(x: -8, y: 1)
                TaskPaper().rotationEffect(.degrees(7)).offset(x: 4, y: -3)
            }
            .frame(height: 96)
            .accessibilityHidden(true)
            Text(emptyLibrary ? L("清单还是空的", "Your list is empty") : filter == .done ? L("还没有已完成的事项", "No completed tasks yet") : L("所有事项都已完成", "All tasks are complete"))
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 12)
            if emptyLibrary {
                Button(L("添加第一项", "Add your first task"), action: addTask)
                    .accessibilityLabel(L("输入新待办", "Enter a new task"))
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.accent)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TaskEntryRow: View {
    let item: InterludeTask
    @Binding var editingID: UUID?
    @Binding var draft: String
    let minutes: Int
    let rounds: Int
    let expanded: Bool
    let showDetails: () -> Void
    let startFocus: ((InterludeTask) -> Void)?
    let toggle: () -> Void
    let rename: (String) -> Bool
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.motionAmount) private var motionAmount
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var rowMotion: Animation? {
        systemReduceMotion || motionAmount <= 0 ? nil : .spring(response: 0.24, dampingFraction: 0.83)
    }
    @FocusState private var editFocused: Bool

    private var isEditing: Bool { editingID == item.id }
    private var emptyDraft: Bool { !TaskStore.validTitle(draft) }

    private var summary: String {
        var parts: [String] = []
        if !item.subtasks.isEmpty {
            let done = item.subtasks.filter(\.completed).count
            parts.append(L("子步骤 \(done)/\(item.subtasks.count)", "Subtasks \(done)/\(item.subtasks.count)"))
        }
        if let planned = item.plannedRounds {
            parts.append(L("预计 \(planned) 轮 · 实际 \(rounds) 轮", "Planned \(planned) · Actual \(rounds) \(rounds == 1 ? "round" : "rounds")"))
        } else if rounds > 0 {
            parts.append(L("实际 \(rounds) 轮", "Actual \(rounds) \(rounds == 1 ? "round" : "rounds")"))
        }
        if minutes > 0 { parts.append(L("\(minutes) 分钟", "\(minutes) min")) }
        return parts.joined(separator: " · ")
    }

    private func edit() {
        draft = item.title
        editingID = item.id
    }

    private func commit() {
        if rename(draft) { editingID = nil }
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                ZStack {
                    Circle().strokeBorder(item.completed ? AppPalette.accent : AppPalette.muted.opacity(0.52),
                                          lineWidth: 1.35)
                    if item.completed {
                        Circle().fill(AppPalette.accent)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .transition(rowMotion == nil ? .identity : .scale(scale: 1 - 0.35 * motionAmount).combined(with: .opacity))
                    }
                }
                .animation(rowMotion, value: item.completed)
                .frame(width: 19, height: 19)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(InterludeButtonStyle(scale: 0.90))
            .accessibilityLabel(item.completed ? L("标记为待完成，", "Mark incomplete: ") + item.title : L("完成，", "Complete: ") + item.title)
            .help(item.completed ? L("标记为待完成", "Mark incomplete") : L("标记为已完成", "Mark complete"))

            if isEditing {
                TextField(L("事项名称", "Task name"), text: $draft)
                    .textFieldStyle(.plain).focused($editFocused)
                    .onSubmit(commit)
                    .onExitCommand { editingID = nil }
                    .onAppear { editFocused = true }
                Button(L("保存", "Save"), action: commit).disabled(emptyDraft)
                    .buttonStyle(.plain).foregroundStyle(AppPalette.accent)
                Button(L("取消", "Cancel")) { editingID = nil }.buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .strikethrough(item.completed, color: AppPalette.muted)
                        .foregroundStyle(item.completed ? AppPalette.muted : AppPalette.ink)
                        .lineLimit(3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: edit)
                        .help(item.title)
                    if item.plannedRounds != nil || rounds > 0 || minutes > 0 || !item.subtasks.isEmpty {
                        Text(summary)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(AppPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: showDetails) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InterludeButtonStyle())
                .foregroundStyle(AppPalette.muted)
                .accessibilityLabel((expanded ? L("收起详情：", "Collapse details: ") : L("展开详情：", "Expand details: ")) + item.title)
                .accessibilityValue(expanded ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
                .help(L("子步骤与预计轮数", "Subtasks and planned rounds"))
                if let startFocus, !item.completed {
                    Button { startFocus(item) } label: {
                        Label(L("专注", "Focus"), systemImage: "timer")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(AppPalette.accent.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(InterludeButtonStyle())
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityLabel(L("开始专注：" + item.title, "Focus on " + item.title))
                    .help(L("为此事项开始专注，自动累计时长", "Start focusing on this task and track its time"))
                }
                Menu {
                    Button(L("编辑事项", "Edit task"), systemImage: "pencil", action: edit)
                    Button(L("删除事项", "Delete task"), systemImage: "trash", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("事项操作，", "Task actions: ") + item.title)
                .foregroundStyle(AppPalette.muted)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppPalette.accent.opacity(hovering ? 0.055 : 0))
        .animation(rowMotion, value: hovering)
        .onHover { hovering = $0 }
    }
}

struct TasksPage: View {
    @ObservedObject var store: TaskStore
    var startFocus: ((InterludeTask) -> Void)? = nil
    var focusMinutes: (UUID) -> Int = { _ in 0 }
    var completedRounds: (UUID) -> Int = { _ in 0 }
    @Environment(\.motionAmount) private var motionAmount
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || motionAmount <= 0 }
    @FocusState private var entryFocused: Bool
    @Namespace private var selection

    private var visible: [InterludeTask] {
        switch store.filter {
        case .open: return store.items.filter { !$0.completed }
        case .done: return store.items.filter(\.completed)
        case .all: return store.items
        }
    }
    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: max(0.12, 0.32 * motionAmount), dampingFraction: 0.88)
    }
    private func add() {
        withAnimation(motion) {
            if store.add(store.newTitle) {
                store.newTitle = ""
                if store.filter == .done { store.filter = .open }
                entryFocused = true
            }
        }
    }
    private func count(for group: TaskFilter) -> Int {
        switch group {
        case .all: return store.items.count
        case .open: return store.pendingCount
        case .done: return store.completedCount
        }
    }

    private var composer: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AppPalette.accent)
                .accessibilityHidden(true)
            TextField(L("添加新的待办事项…", "Add a task…"), text: $store.newTitle)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($entryFocused)
                .onSubmit(add)
            Button(action: add) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text(L("添加", "Add")).font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14).frame(height: 30)
                .foregroundStyle(.white)
                .background(Color.black.opacity(store.newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.43 : 0.85),
                            in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(InterludeButtonStyle())
            .disabled(!TaskStore.validTitle(store.newTitle) || store.items.count >= TaskStore.maximumTasks)
        }
        .padding(.leading, 18).padding(.trailing, 12)
        .frame(height: 55)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(entryFocused ? AppPalette.accent : AppPalette.line))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16 * motionAmount), value: entryFocused)
    }

    private var filters: some View {
        HStack(spacing: 3) {
            ForEach(TaskFilter.allCases, id: \.self) { group in
                Button {
                    withAnimation(motion) {
                        store.editingID = nil
                        store.filter = group
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(group.title).font(.system(size: 13, weight: .medium))
                        Text("\(count(for: group))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .opacity(0.70)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .foregroundStyle(store.filter == group ? AppPalette.paper : AppPalette.muted)
                    .background {
                        if store.filter == group {
                            RoundedRectangle(cornerRadius: 6).fill(AppPalette.ink)
                                .matchedGeometryEffect(id: "task-filter", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store.filter == group ? .isSelected : [])
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            composer
            filters
            ZStack {
                if visible.isEmpty {
                    EmptyTasks(filter: store.filter, emptyLibrary: store.items.isEmpty) { entryFocused = true }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { item in
                                VStack(spacing: 0) {
                                    TaskEntryRow(item: item, editingID: $store.editingID, draft: $store.renameDraft,
                                                 minutes: focusMinutes(item.id), rounds: completedRounds(item.id),
                                                 expanded: store.expandedID == item.id, showDetails: {
                                        withAnimation(motion) { store.expandedID = store.expandedID == item.id ? nil : item.id }
                                    }, startFocus: startFocus) {
                                        withAnimation(motion) { store.toggle(item.id) }
                                    } rename: { name in
                                        store.rename(item.id, to: name)
                                    } remove: {
                                        withAnimation(motion) { store.remove(item.id) }
                                    }
                                    if store.expandedID == item.id {
                                        TaskDetailsView(store: store, taskID: item.id,
                                                        minutes: focusMinutes(item.id), rounds: completedRounds(item.id))
                                            .transition(reduceMotion ? .identity : .opacity)
                                    }
                                    Divider().padding(.leading, 56)
                                }
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6 * motionAmount)))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppPalette.line))
            if let error = store.storageError {
                HStack {
                    Text(error)
                    Spacer()
                    Button(L("重新读取", "Reload")) { store.load() }
                }
                .font(.system(size: 12)).foregroundStyle(AppPalette.accent)
            } else if store.deleted != nil {
                HStack(spacing: 10) {
                    Text(L("已删除一项待办", "Task deleted"))
                    Button(L("撤销", "Undo")) { withAnimation(motion) { store.undoRemoval() } }
                        .foregroundStyle(AppPalette.accent)
                    Spacer()
                    Button { store.dismissUndo() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L("关闭撤销提示", "Dismiss undo"))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(AppPalette.muted)
            }
        }
    }
}
