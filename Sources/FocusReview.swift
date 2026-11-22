import SwiftUI

struct FocusRecoveryCard: View {
    @ObservedObject var model: FocusModel

    var body: some View {
        if model.hasRecovery {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("有一个中断的时段", "An interrupted session"), systemImage: "pause.circle")
                    .font(.headline)
                Text(L("\(model.modeLabel)还剩 \(model.remainingLabel)。休眠或退出后的时间未计入专注。",
                       "\(model.modeLabel) has \(model.remainingLabel) left. Time asleep or away from the app has not been counted."))
                    .font(.subheadline).foregroundStyle(AppPalette.muted)
                if let title = model.selectedTaskTitle {
                    Label(title, systemImage: "checklist").font(.subheadline).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button(L("继续计时", "Resume")) { model.resolveRecovery(.resume) }
                        .buttonStyle(.borderedProminent)
                    Button(L("记录已用时间", "Record elapsed time")) { model.resolveRecovery(.recordElapsed) }
                        .disabled(model.recoveryElapsedSeconds == 0)
                        .help(L("保存中断前的专注时间，不计为完整轮次。", "Save focus time before the interruption without counting a completed round."))
                    Button(L("放弃此时段", "Discard session"), role: .destructive) { model.resolveRecovery(.discard) }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.accent.opacity(0.35)))
            .accessibilityElement(children: .contain)
        }
    }
}

struct FocusSummaryBanner: View {
    @ObservedObject var model: FocusModel
    @State private var editingRecord: FocusRecord?

    var body: some View {
        if let record = model.latestSummary {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.completedRound ? L("一轮专注已完成", "Focus session complete") : L("已保存中断前的专注", "Elapsed focus saved"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(focusRecordDuration(record.seconds) + " · " + (record.taskTitle ?? L("未关联事项", "Unassigned")))
                        .font(.caption).foregroundStyle(AppPalette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(L("回顾一下", "Reflect")) { editingRecord = record }
                Button { model.dismissSummary() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("收起专注小结", "Dismiss focus summary"))
                    .help(L("可随时在统计页查看和填写回顾。", "Review or edit this session anytime in Statistics."))
            }
            .padding(13).background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.line))
            .sheet(item: $editingRecord) { record in FocusReviewEditor(model: model, record: record) }
        }
    }
}

struct FocusReviewHistory: View {
    @ObservedObject var model: FocusModel
    @State private var editingRecord: FocusRecord?
    @State private var visibleCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("专注回顾", "Session reflections")).font(.headline)
            if model.reviewRecords.isEmpty {
                Text(L("结束一段专注后，可以在这里写下收获和下一步。", "After a focus session, capture what you learned and your next step here."))
                    .font(.subheadline).foregroundStyle(AppPalette.muted)
            } else {
                ForEach(model.reviewRecords.prefix(visibleCount)) { record in
                    Button { editingRecord = record } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: record.completedRound ? "checkmark.circle" : "clock")
                                .foregroundStyle(AppPalette.accent).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(record.taskTitle ?? L("未关联事项", "Unassigned")).fontWeight(.medium).lineLimit(1)
                                    Spacer()
                                    Text(focusRecordDuration(record.seconds)).monospacedDigit()
                                }
                                Text(record.end.formatted(date: .abbreviated, time: .shortened) + " · " +
                                     (record.completedRound ? L("完整轮次", "Completed round") : L("部分时段", "Partial session")))
                                    .font(.caption).foregroundStyle(AppPalette.muted)
                                if let reflection = record.reflection {
                                    Text(L("收获：", "Reflection: ") + reflection).lineLimit(2)
                                }
                                if let next = record.nextStep {
                                    Text(L("下一步：", "Next step: ") + next).lineLimit(2)
                                }
                                if record.reflection == nil && record.nextStep == nil {
                                    Text(L("添加收获与下一步", "Add a reflection and next step")).foregroundStyle(AppPalette.muted)
                                }
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppPalette.muted)
                        }
                        .font(.system(size: 12)).contentShape(Rectangle())
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L("打开并编辑这段专注的回顾", "Open and edit this session's reflection"))
                    Divider()
                }
                if model.reviewRecords.count > visibleCount {
                    Button(L("显示更早的回顾", "Show earlier sessions")) { visibleCount += 20 }
                }
            }
        }
        .padding(16).background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.line))
        .sheet(item: $editingRecord) { record in FocusReviewEditor(model: model, record: record) }
    }
}

private struct FocusReviewEditor: View {
    @ObservedObject var model: FocusModel
    let record: FocusRecord
    @Environment(\.dismiss) private var dismiss
    @State private var reflection: String
    @State private var nextStep: String

    init(model: FocusModel, record: FocusRecord) {
        self.model = model
        self.record = record
        _reflection = State(initialValue: record.reflection ?? "")
        _nextStep = State(initialValue: record.nextStep ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("专注小结", "Session summary")).font(.title2.bold())
            VStack(alignment: .leading, spacing: 5) {
                Text(record.taskTitle ?? L("未关联事项", "Unassigned")).font(.headline)
                Text(focusRecordDuration(record.seconds) + " · " + record.end.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(AppPalette.muted)
                Text(record.completedRound ? L("已完成一轮专注", "One focus round completed") : L("已保存的部分专注时段", "Saved partial focus session"))
                    .font(.caption).foregroundStyle(AppPalette.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    noteField(L("这次完成了什么？有什么收获？", "What did you accomplish or learn?"), text: $reflection)
                    noteField(L("接下来做什么？", "What is your next step?"), text: $nextStep)
                }
            }
            Text(L("笔记仅保存在这台 Mac，并会包含在本地备份中。计时会继续运行。", "Notes stay on this Mac and are included in local backups. The timer keeps running."))
                .font(.caption).foregroundStyle(AppPalette.muted)
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存回顾", "Save reflection")) {
                    model.saveReview(id: record.id, reflection: reflection, nextStep: nextStep)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(reflection.count > 4_000 || nextStep.count > 4_000)
            }
        }
        .padding(24).frame(width: 520, height: 560)
        .foregroundStyle(AppPalette.ink)
    }

    private func noteField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            TextEditor(text: text).font(.body)
                .frame(minHeight: 90)
                .padding(6)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppPalette.line))
                .accessibilityLabel(title)
            Text("\(text.wrappedValue.count) / 4000").font(.caption)
                .foregroundStyle(text.wrappedValue.count > 4_000 ? Color.red : AppPalette.muted)
        }
    }
}

private func focusRecordDuration(_ seconds: Int) -> String {
    if seconds < 60 { return L("\(seconds) 秒", "\(seconds) sec") }
    return L("\(seconds / 60) 分钟", "\(seconds / 60) min")
}
