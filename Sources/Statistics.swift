import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct FocusTotals {
    var seconds = 0
    var rounds = 0

    mutating func add(_ record: FocusRecord) {
        seconds += record.seconds
        if record.completedRound { rounds += 1 }
    }
}

private enum StatisticsRange: CaseIterable {
    case today, week, allTime

    var title: String {
        switch self {
        case .today: return L("今天", "Today")
        case .week: return L("本周", "This week")
        case .allTime: return L("全部", "All time")
        }
    }
}

private struct TaskTotal: Identifiable {
    let id: UUID?
    var title: String
    var seconds = 0
    var latest = Date.distantPast
}

private struct StatisticsSnapshot {
    let calendar: Calendar
    let now: Date
    let firstWeek: Date
    var byDay: [Date: FocusTotals] = [:]
    var today = FocusTotals()
    var week = FocusTotals()
    var tasks: [TaskTotal] = []

    init(records: [FocusRecord], range: StatisticsRange, calendar: Calendar, now: Date) {
        self.calendar = calendar
        self.now = now
        let todayStart = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        firstWeek = calendar.date(byAdding: .day, value: -77, to: thisWeek) ?? thisWeek
        var byTask: [UUID?: TaskTotal] = [:]
        for record in records where record.seconds > 0 && record.end <= now {
            let day = calendar.startOfDay(for: record.end)
            byDay[day, default: FocusTotals()].add(record)
            let inWeek = day >= thisWeek
            let isToday = day == todayStart
            if inWeek { week.add(record) }
            if isToday { today.add(record) }
            if range == .today && !isToday || range == .week && !inWeek { continue }
            let title = record.taskTitle ?? L("未关联事项", "Unassigned")
            var task = byTask[record.taskID] ?? TaskTotal(id: record.taskID, title: title)
            task.seconds += record.seconds
            if record.end >= task.latest {
                task.title = title
                task.latest = record.end
            }
            byTask[record.taskID] = task
        }
        tasks = byTask.values.sorted {
            if $0.seconds == $1.seconds { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.seconds > $1.seconds
        }
    }

    func day(week: Int, weekday: Int) -> Date {
        calendar.date(byAdding: .day, value: week * 7 + weekday, to: firstWeek) ?? firstWeek
    }
}

private func focusTimeDescription(_ seconds: Int) -> String {
    let minutes = seconds / 60
    if seconds > 0 && minutes == 0 { return L("不足 1 分钟", "< 1 min") }
    if minutes < 60 { return L("\(minutes) 分钟", "\(minutes) min") }
    return L("\(minutes / 60) 小时 \(minutes % 60) 分钟", "\(minutes / 60) hr \(minutes % 60) min")
}

struct StatisticsPage: View {
    @ObservedObject var model: FocusModel
    @Environment(\.locale) private var locale
    @State private var range = StatisticsRange.week
    @State private var selectedDay: Date?
    @State private var appeared = false
    @State private var exportError: String?
    @Namespace private var calendarHighlight
    @Environment(\.motionAmount) private var motionAmount
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduced: Bool { systemReduceMotion || motionAmount <= 0 }

    var body: some View {
        let data = StatisticsSnapshot(records: model.statisticsRecords, range: range,
                                      calendar: .autoupdatingCurrent, now: Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    totalCard(L("今日专注", "Today"), data.today, icon: "sun.max")
                    totalCard(L("本周专注", "This week"), data.week, icon: "calendar")
                }
                .opacity(appeared || reduced ? 1 : 0.82)
                .animation(reduced ? nil : .easeOut(duration: 0.20), value: appeared)
                calendarView(data)
                    .offset(y: appeared || reduced ? 0 : 5 * motionAmount)
                    .opacity(appeared || reduced ? 1 : 0.84)
                    .animation(reduced ? nil : .easeOut(duration: 0.24).delay(0.04), value: appeared)
                breakdown(data)
                FocusReviewHistory(model: model)
                HStack(spacing: 12) {
                    Button { exportCSV() } label: {
                        Label(L("导出 CSV（" + range.title + "）", "Export CSV (" + range.title + ")"), systemImage: "tablecells")
                    }
                    Button { exportWeeklyImage() } label: {
                        Label(L("保存本周周报图片", "Save weekly report image"), systemImage: "photo")
                    }
                }
                .padding(.bottom, 3)
            }
            .padding(1)
        }
        .foregroundStyle(AppPalette.ink)
        .onAppear { appeared = true }
        .alert(L("未能导出", "Export failed"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(L("好", "OK")) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func saveURL(type: UTType, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportCSV() {
        guard let url = saveURL(type: .commaSeparatedText, name: L("间奏-专注记录.csv", "Interlude-focus-records.csv")) else { return }
        let calendar = Calendar.autoupdatingCurrent
        let snapshot = model.statisticsRecords
        let now = Date()
        let since: Date
        switch range {
        case .today: since = calendar.startOfDay(for: now)
        case .week: since = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        case .allTime: since = .distantPast
        }
        let records = snapshot.filter { $0.seconds > 0 && $0.end >= since && $0.end <= now }
        do { try StatisticsExport.csv(records: records, english: AppLanguage.current == .english).write(to: url, options: .atomic) }
        catch { exportError = error.localizedDescription }
    }

    private func exportWeeklyImage() {
        guard let url = saveURL(type: .png, name: L("间奏-专注周报.png", "Interlude-weekly-report.png")) else { return }
        do {
            let png = try StatisticsExport.weeklyPNG(records: model.statisticsRecords, now: .now, calendar: .autoupdatingCurrent,
                                                     locale: locale, english: AppLanguage.current == .english)
            try png.write(to: url, options: .atomic)
        } catch { exportError = error.localizedDescription }
    }

    private func totalCard(_ title: String, _ total: FocusTotals, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Text(focusTimeDescription(total.seconds))
                .font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(L("已完成 \(total.rounds) 轮", "Sessions completed: \(total.rounds)"))
                .font(.caption).foregroundStyle(AppPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.line))
    }

    private func calendarView(_ data: StatisticsSnapshot) -> some View {
        let formatter = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        let inspected = selectedDay ?? data.calendar.startOfDay(for: data.now)
        let detail = data.byDay[inspected] ?? FocusTotals()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("专注日历", "Focus calendar")).font(.headline)
                Spacer()
                Text(L("最近 12 周", "Last 12 weeks")).font(.caption).foregroundStyle(AppPalette.muted)
            }
            Grid(horizontalSpacing: 5, verticalSpacing: 4) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(0..<12, id: \.self) { week in
                        let day = data.day(week: week, weekday: 0)
                        let last = data.day(week: max(0, week - 1), weekday: 0)
                        let startsMonth = week == 0 || data.calendar.component(.month, from: day) != data.calendar.component(.month, from: last)
                        Text(startsMonth ? day.formatted(.dateTime.month(.abbreviated).locale(locale)) : "")
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(0..<7, id: \.self) { day in
                    GridRow {
                        Text(data.day(week: 0, weekday: day).formatted(.dateTime.weekday(.abbreviated).locale(locale)))
                            .font(.system(size: 10)).foregroundStyle(AppPalette.muted)
                            .frame(minWidth: 32, alignment: .leading)
                        ForEach(0..<12, id: \.self) { week in
                            let date = data.day(week: week, weekday: day)
                            let seconds = data.byDay[date]?.seconds ?? 0
                            let future = date > data.now
                            Button {
                                selectedDay = date
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(heatColor(seconds))
                                    .frame(maxWidth: .infinity).frame(height: 13)
                                    .overlay {
                                        if !future && data.calendar.isDate(date, inSameDayAs: inspected) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(AppPalette.ink, lineWidth: 1.5)
                                                .matchedGeometryEffect(id: "selected-day", in: calendarHighlight)
                                        }
                                    }
                            }
                            .opacity(future ? 0.2 : 1)
                            .buttonStyle(.plain).disabled(future)
                            .help(date.formatted(formatter) + " · " + focusTimeDescription(seconds))
                            .accessibilityLabel(date.formatted(formatter))
                            .accessibilityValue(focusTimeDescription(seconds))
                        }
                    }
                }
            }
            .animation(reduced ? nil : .spring(response: 0.26, dampingFraction: 0.88), value: selectedDay)
            HStack(spacing: 5) {
                Text(inspected.formatted(formatter) + " · " + focusTimeDescription(detail.seconds))
                Spacer()
                Text(L("少", "Less"))
                ForEach([0, 1, 15, 30, 60], id: \.self) { minutes in
                    RoundedRectangle(cornerRadius: 2).fill(heatColor(minutes * 60))
                        .frame(width: 10, height: 10)
                }
                Text(L("多", "More"))
            }
            .font(.caption).foregroundStyle(AppPalette.muted)
        }
        .padding(16)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.line))
    }

    private func heatColor(_ seconds: Int) -> Color {
        guard seconds > 0 else { return AppPalette.ink.opacity(0.08) }
        switch seconds / 60 {
        case 0..<15: return AppPalette.accent.opacity(0.30)
        case 15..<30: return AppPalette.accent.opacity(0.50)
        case 30..<60: return AppPalette.accent.opacity(0.73)
        default: return AppPalette.accent
        }
    }

    private func breakdown(_ data: StatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(L("按事项统计", "Time by task")).font(.headline)
                Spacer()
                Picker(L("统计范围", "Date range"), selection: $range) {
                    ForEach(StatisticsRange.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if data.tasks.isEmpty {
                Text(L("所选时段还没有专注记录。", "No focus time in this period."))
                    .font(.subheadline).foregroundStyle(AppPalette.muted)
            } else {
                ForEach(data.tasks) { task in
                    HStack {
                        Text(task.title).lineLimit(2)
                        Spacer()
                        Text(focusTimeDescription(task.seconds)).monospacedDigit()
                    }
                    .font(.system(size: 13))
                    Divider()
                }
            }
            Text(L("专注时长包含已用的部分时段，轮数只计完整时段。跨日时段按结束日归档。",
                   "Focus time includes partial sessions. Only completed sessions count as rounds. Sessions are grouped by their end date."))
                .font(.system(size: 11)).foregroundStyle(AppPalette.muted)
        }
        .padding(16)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppPalette.line))
    }
}

enum StatisticsExport {
    static func csv(records: [FocusRecord], english: Bool) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let headers = english ? ["End time", "Seconds", "Completed round", "Task ID", "Task", "Reflection", "Next step"] : ["结束时间", "专注秒数", "完整轮次", "事项编号", "事项名称", "收获", "下一步"]
        var output = "\u{FEFF}" + line(headers)
        for record in records.sorted(by: { $0.end < $1.end }) {
            let completed = record.completedRound ? (english ? "Yes" : "是") : (english ? "No" : "否")
            output += line([formatter.string(from: record.end), String(record.seconds), completed,
                            record.taskID?.uuidString ?? "", record.taskTitle ?? (english ? "Unassigned" : "未关联事项"),
                            record.reflection ?? "", record.nextStep ?? ""])
        }
        return Data(output.utf8)
    }

    private static func line(_ columns: [String]) -> String {
        columns.map { text in
            // Quoting alone does not stop spreadsheet formulas. Check after invisible leading characters, too.
            let invisible = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(.illegalCharacters)
            let firstVisible = text.unicodeScalars.first { !invisible.contains($0) && $0.value != 0xfeff }
            let prefix = firstVisible.map { "=+-@＝＋－＠".unicodeScalars.contains($0) } == true ? "'" : ""
            return "\"" + prefix + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") + "\r\n"
    }

    @MainActor
    static func weeklyPNG(records: [FocusRecord], now: Date, calendar: Calendar, locale: Locale, english: Bool) throws -> Data {
        let report = WeeklyReport(records: records, now: now, calendar: calendar, locale: locale, english: english)
            .environment(\.locale, locale)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: report)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

private struct WeeklyReport: View {
    let now: Date
    let calendar: Calendar
    let locale: Locale
    let english: Bool
    let days: [Date]
    let totals: StatisticsSnapshot
    let ink = Color(red: 0.14, green: 0.15, blue: 0.14)
    let muted = Color(red: 0.34, green: 0.36, blue: 0.33)
    let accent = Color(red: 0.78, green: 0.29, blue: 0.14)

    init(records: [FocusRecord], now: Date, calendar: Calendar, locale: Locale, english: Bool) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.english = english
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        totals = StatisticsSnapshot(records: records, range: .week, calendar: calendar, now: now)
    }

    func duration(_ seconds: Int) -> String {
        if seconds > 0 && seconds < 60 { return english ? "< 1 min" : "不足 1 分钟" }
        let minutes = seconds / 60
        if minutes < 60 { return english ? "\(minutes) min" : "\(minutes) 分钟" }
        return english ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    var body: some View {
        let peak = max(1, days.map { totals.byDay[$0]?.seconds ?? 0 }.max() ?? 0)
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text(english ? "Weekly focus report" : "本周专注报告").font(.system(size: 34, weight: .semibold))
                Spacer()
                Text(english ? "Interlude" : "间奏").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(accent)
            }
            Text((days.first ?? now).formatted(dateStyle) + " – " + (days.last ?? now).formatted(dateStyle))
                .font(.system(size: 15)).foregroundStyle(muted)
            Divider()
            HStack(alignment: .top, spacing: 68) {
                metric(english ? "Focus time" : "专注时长", duration(totals.week.seconds))
                metric(english ? "Completed rounds" : "完成轮数", String(totals.week.rounds))
                metric(english ? "Active days" : "专注天数", String(days.filter { (totals.byDay[$0]?.seconds ?? 0) > 0 }.count))
            }
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(days, id: \.self) { day in
                    let seconds = totals.byDay[day]?.seconds ?? 0
                    VStack(spacing: 8) {
                        Text(seconds == 0 ? "–" : duration(seconds)).font(.system(size: 12, weight: .medium))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(seconds > 0 ? accent : muted.opacity(0.25))
                            .frame(height: seconds == 0 ? 1 : max(4, 88 * CGFloat(seconds) / CGFloat(peak)))
                        Text(day.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)))
                            .font(.system(size: 13)).foregroundStyle(muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140, alignment: .bottom)
            Divider()
            Text(english ? "Time by task" : "事项用时").font(.system(size: 18, weight: .semibold))
            if totals.tasks.isEmpty {
                Text(english ? "No focus sessions recorded this week." : "本周尚无专注记录。").foregroundStyle(muted)
            } else {
                ForEach(totals.tasks.prefix(3)) { task in
                    HStack {
                        Text(task.id == nil ? (english ? "Unassigned" : "未关联事项") : task.title).lineLimit(1)
                        Spacer()
                        Text(duration(task.seconds)).monospacedDigit()
                    }
                    .font(.system(size: 15))
                }
            }
        }
        .foregroundStyle(ink)
        .padding(36)
        .frame(width: 764, alignment: .leading)
        .background(Color(red: 0.968, green: 0.961, blue: 0.933))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(muted)
            Text(value).font(.system(size: 26, weight: .medium)).monospacedDigit()
        }
    }
}
