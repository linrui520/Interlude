import SwiftUI

struct TaskDetailsView: View {
    @ObservedObject var store: TaskStore
    let taskID: UUID
    let minutes: Int
    let rounds: Int
    @State private var newSubtask = ""
    @FocusState private var entryFocused: Bool

    private var task: InterludeTask? { store.items.first { $0.id == taskID } }

    private func add() {
        if store.addSubtask(to: taskID, title: newSubtask) {
            newSubtask = ""
            entryFocused = true
        }
    }

    var body: some View {
        if let task {
            VStack(alignment: .leading, spacing: 14) {
                planning(task)
                Divider()
                HStack {
                    Text(L("子步骤", "Subtasks")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(task.subtasks.filter(\.completed).count)/\(task.subtasks.count)")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(AppPalette.muted)
                        .accessibilityLabel(L("已完成 \(task.subtasks.filter(\.completed).count) 个，共 \(task.subtasks.count) 个子步骤",
                                              "\(task.subtasks.filter(\.completed).count) of \(task.subtasks.count) subtasks complete"))
                }
                if task.subtasks.isEmpty {
                    Text(L("把事项拆成几个小步骤，逐项推进。", "Break this task into smaller steps."))
                        .font(.system(size: 12)).foregroundStyle(AppPalette.muted)
                }
                ForEach(task.subtasks) { subtask in
                    SubtaskEntryRow(item: subtask, toggle: {
                        _ = store.toggleSubtask(subtask.id, in: taskID)
                    }, rename: { title in
                        store.renameSubtask(subtask.id, in: taskID, to: title)
                    }, remove: {
                        _ = store.removeSubtask(subtask.id, from: taskID)
                    })
                }
                HStack(spacing: 8) {
                    TextField(L("添加子步骤…", "Add a subtask…"), text: $newSubtask)
                        .textFieldStyle(.roundedBorder)
                        .focused($entryFocused)
                        .onSubmit(add)
                        .accessibilityLabel(L("新子步骤名称", "New subtask name"))
                    Button(action: add) {
                        Label(L("添加", "Add"), systemImage: "plus")
                    }
                    .disabled(!TaskStore.validTitle(newSubtask) || task.subtasks.count >= TaskStore.maximumSubtasks)
                    .help(L("按回车添加子步骤", "Press Return to add a subtask"))
                }
                if task.subtasks.count >= TaskStore.maximumSubtasks {
                    Text(L("每项待办最多添加 \(TaskStore.maximumSubtasks) 个子步骤。",
                           "Each task can have up to \(TaskStore.maximumSubtasks) subtasks."))
                        .font(.caption).foregroundStyle(AppPalette.muted)
                }
                Text(L("子步骤可独立勾选；主事项由你手动标记完成。",
                       "Check off subtasks independently; mark the main task complete when you are ready."))
                    .font(.system(size: 11)).foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(AppPalette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 14)
        }
    }

    private func planning(_ task: InterludeTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Stepper(value: Binding(get: { task.plannedRounds ?? 0 }, set: { value in
                _ = store.setPlannedRounds(taskID, to: value == 0 ? nil : value)
            }), in: 0...TaskStore.maximumPlannedRounds) {
                Text(task.plannedRounds.map { L("预计专注 \($0) 轮", $0 == 1 ? "Planned: 1 focus round" : "Planned: \($0) focus rounds") }
                     ?? L("预计轮数：未设置", "Planned rounds: not set"))
                    .font(.system(size: 12, weight: .medium))
            }
            .accessibilityLabel(L("预计专注轮数", "Planned focus rounds"))
            .accessibilityValue(task.plannedRounds.map(String.init) ?? L("未设置", "Not set"))
            .help(L("设置 1–99 轮；减到 0 可清除预计。", "Choose 1–99 rounds; decrease to 0 to clear the estimate."))
            Text(L("实际完成 \(rounds) 轮 · 已记录 \(minutes) 分钟", "Actual: \(rounds) completed \(rounds == 1 ? "round" : "rounds") · \(minutes) recorded min"))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(AppPalette.ink)
            if let planned = task.plannedRounds {
                Text(comparison(planned: planned))
                    .font(.system(size: 11)).foregroundStyle(AppPalette.muted)
            }
            Text(L("实际轮数只计算完成的专注；分钟数来自此事项的专注记录。",
                   "Actual rounds count completed focus sessions. Minutes come from this task’s focus history."))
                .font(.system(size: 11)).foregroundStyle(AppPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func comparison(planned: Int) -> String {
        if rounds < planned {
            let difference = planned - rounds
            return L("比预计少 \(difference) 轮", difference == 1 ? "1 round below estimate" : "\(difference) rounds below estimate")
        }
        if rounds > planned {
            let difference = rounds - planned
            return L("比预计多 \(difference) 轮", difference == 1 ? "1 round above estimate" : "\(difference) rounds above estimate")
        }
        return L("实际轮数与预计一致", "Actual rounds match the estimate")
    }
}

private struct SubtaskEntryRow: View {
    let item: TaskSubtask
    let toggle: () -> Void
    let rename: (String) -> Bool
    let remove: () -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editFocused: Bool

    private func edit() { draft = item.title; editing = true }
    private func commit() { if rename(draft) { editing = false } }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15)).foregroundStyle(item.completed ? AppPalette.accent : AppPalette.muted)
                    .frame(width: 24, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((item.completed ? L("标记子步骤为待完成：", "Mark subtask incomplete: ") : L("完成子步骤：", "Complete subtask: ")) + item.title)
            .accessibilityValue(item.completed ? L("已完成", "Complete") : L("待完成", "Incomplete"))
            .help(L("切换子步骤完成状态", "Toggle subtask completion"))
            if editing {
                TextField(L("子步骤名称", "Subtask name"), text: $draft)
                    .textFieldStyle(.roundedBorder).focused($editFocused)
                    .onSubmit(commit).onExitCommand { editing = false }
                    .onAppear { editFocused = true }
                Button(L("保存", "Save"), action: commit).disabled(!TaskStore.validTitle(draft))
                Button(L("取消", "Cancel")) { editing = false }
            } else {
                Text(item.title)
                    .strikethrough(item.completed, color: AppPalette.muted)
                    .foregroundStyle(item.completed ? AppPalette.muted : AppPalette.ink)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.title)
                Menu {
                    Button(L("编辑子步骤", "Edit subtask"), systemImage: "pencil", action: edit)
                    Button(L("删除子步骤", "Delete subtask"), systemImage: "trash", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 26, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("子步骤操作：", "Subtask actions: ") + item.title)
                .help(L("编辑或删除子步骤", "Edit or delete this subtask"))
            }
        }
        .font(.system(size: 12))
    }
}
