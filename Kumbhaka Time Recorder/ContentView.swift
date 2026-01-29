// ContentView.swift
import SwiftUI
import SwiftData
import AudioToolbox

// 表示形式
enum TimeDisplayStyle: String, CaseIterable, Identifiable {
    case minuteSecond
    case decimalSecond

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minuteSecond: return "何分何秒"
        case .decimalSecond: return "秒（小数1位）"
        }
    }
}

// 目標達成時の強調色（設定用：必要最低限の選択肢）
enum GoalHighlightColor: String, CaseIterable, Identifiable {
    case red
    case orange
    case blue
    case purple
    case black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .red: return "赤"
        case .orange: return "オレンジ"
        case .blue: return "青"
        case .purple: return "紫"
        case .black: return "黒"
        }
    }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .blue: return .blue
        case .purple: return .purple
        case .black: return .black
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    // 今日分の履歴（起動時に今日の範囲でQueryを作る）
    @Query private var todaySessions: [SessionRecord]

    // 設定（永続）
    @AppStorage("rechakaStartMode") private var rechakaStartModeRaw: String = RechakaStartMode.auto.rawValue
    private var rechakaStartMode: RechakaStartMode {
        RechakaStartMode(rawValue: rechakaStartModeRaw) ?? .auto
    }

    // 表示形式（デフォルト「何分何秒」）
    @AppStorage("timeDisplayStyle") private var timeDisplayStyleRaw: String = TimeDisplayStyle.minuteSecond.rawValue
    private var timeDisplayStyle: TimeDisplayStyle {
        TimeDisplayStyle(rawValue: timeDisplayStyleRaw) ?? .minuteSecond
    }

    // ★目標（秒）と強調色（新規）
    @AppStorage("goalSeconds") private var goalSeconds: Double = 0.0                 // 0=無効扱い
    @AppStorage("goalHighlightColor") private var goalColorRaw: String = GoalHighlightColor.red.rawValue
    private var goalColor: Color {
        (GoalHighlightColor(rawValue: goalColorRaw) ?? .red).color
    }

    // ===== 安定するまで false =====
    @State private var isReady = false
    @State private var lastTick: Date = Date()
    @State private var stableSince: Date? = nil

    private let tickInterval: UInt64 = 100_000_000
    private let hangThreshold: TimeInterval = 0.25
    private let requiredStable: TimeInterval = 2.0

    // ===== フェーズ（最初がレーチャカ、次がプーラカ）=====
    private enum Phase {
        case idle
        case startToRechaka
        case waitPuraakaStart
        case puraakaRunning
    }
    @State private var phase: Phase = .idle

    // ===== 時刻 =====
    @State private var startedAt: Date?
    @State private var rechakaAt: Date?
    @State private var puraakaAt: Date?

    // ===== 直近完了セッション（共有用） =====
    @State private var lastCompletedStartedAt: Date?

    // ===== 結果（表示は レーチャカ→プーラカ の順）=====
    @State private var lastRechaka: Double?
    @State private var lastPuraaka: Double?

    @State private var now: Date = Date()

    // MARK: - init（今日の範囲Query）
    init() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)

        _todaySessions = Query(
            filter: #Predicate<SessionRecord> { $0.startedAt >= start && $0.startedAt < end },
            sort: \SessionRecord.startedAt,
            order: .reverse
        )
    }

    // MARK: - Button Titles

    private var startButtonTitle: String {
        switch rechakaStartMode {
        case .auto:
            return "スタート"
        case .manual:
            switch phase {
            case .idle:
                return "レーチャカスタート"
            case .waitPuraakaStart:
                return "プーラカスタート"
            default:
                return "スタート"
            }
        }
    }

    private var rechakaStopButtonTitle: String {
        rechakaStartMode == .manual ? "レーチャカストップ" : "レーチャカ"
    }

    private var puraakaStopButtonTitle: String {
        rechakaStartMode == .manual ? "プーラカストップ" : "プーラカ"
    }

    private var canTapStart: Bool {
        phase == .idle || phase == .waitPuraakaStart
    }

    // MARK: - メイン共有（簡易文面）

    private var canShareFromMain: Bool {
        lastCompletedStartedAt != nil && lastRechaka != nil && lastPuraaka != nil
    }

    private var mainShareText: String {
        let started = lastCompletedStartedAt.map { Self.df.string(from: $0) } ?? "—"
        return """
        開始: \(started)
        レーチャカ: \(Self.formatTime(lastRechaka, style: timeDisplayStyle))
        プーラカ: \(Self.formatTime(lastPuraaka, style: timeDisplayStyle))
        """
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                // 秒数表示＋共有
                HStack(spacing: 12) {
                    elapsedHeader

                    ShareLink(item: mainShareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .opacity(canShareFromMain ? 1.0 : 0.35)
                    }
                    .disabled(!canShareFromMain)
                    .buttonStyle(.plain)
                }

                // ボタン群（色：レーチャカ=オレンジ、プーラカ=グリーン）
                VStack(spacing: 14) {
                    bigButton(
                        title: startButtonTitle,
                        enabled: isReady && canTapStart,
                        background: .blue
                    ) {
                        playTapSound()
                        handleStartButton()
                    }

                    bigButton(
                        title: rechakaStopButtonTitle,
                        enabled: isReady && phase == .startToRechaka,
                        background: .orange
                    ) {
                        playTapSound()
                        rechakaStop()
                    }

                    bigButton(
                        title: puraakaStopButtonTitle,
                        enabled: isReady && phase == .puraakaRunning,
                        background: .green
                    ) {
                        playTapSound()
                        finishPuraakaAndSave()
                    }
                }

                // 直近結果（タイトル太字＋秒数黒＋表示形式設定反映）
                VStack(spacing: 8) {
                    simpleResultRow(title: "レーチャカ", value: lastRechaka, titleColor: .orange)
                    simpleResultRow(title: "プーラカ", value: lastPuraaka, titleColor: .green)
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // 今日分の履歴（履歴・設定ボタンの上）
                todayHistoryPanel

                // 履歴 / 設定
                HStack(spacing: 12) {
                    NavigationLink("履歴") { HistoryView() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isReady)

                    NavigationLink("設定") { SettingsView() }
                        .buttonStyle(.bordered)
                        .disabled(!isReady)
                }

                Spacer()

                if !isReady {
                    Text("準備中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .task { await stabilityLoop() }
        }
    }

    // MARK: - 今日分履歴パネル（目標以上で色変更）

    private var todayHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日の記録")
                    .font(.headline)
                    .foregroundColor(.black)

                Spacer()

                Text("\(todaySessions.count)件")
                    .font(.subheadline)
                    .foregroundColor(.black)
            }

            if todaySessions.isEmpty {
                Text("今日の履歴はありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {

                // ヘッダー行
                HStack {
                    Text("時間")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.black)
                        .frame(width: 80, alignment: .center)

                    Spacer().frame(width: 48)

                    Text("レーチャカ")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("プーラカ")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 2)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(todaySessions) { s in
                            let r1 = s.record1Seconds
                            let r2 = s.record2Seconds

                            HStack {
                                Text(Self.timeOnly.string(from: s.startedAt))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.black)
                                    .frame(width: 80, alignment: .center)

                                Spacer().frame(width: 48)

                                // ★目標以上なら色変更（デフォルト赤）
                                Text(Self.formatTime(r1, style: timeDisplayStyle))
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundColor(colorForGoal(r1))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(Self.formatTime(r2, style: timeDisplayStyle))
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundColor(colorForGoal(r2))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxHeight: 170)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func colorForGoal(_ seconds: Double?) -> Color {
        guard goalSeconds > 0 else { return .black }          // 0以下は無効
        guard let s = seconds else { return .black }
        return (s >= goalSeconds) ? goalColor : .black
    }

    // MARK: - Header（経過表示は従来どおり小数1位秒）

    private var elapsedHeader: some View {
        let text = isReady ? elapsedText() : "0.0 秒"
        let show = isReady && phase != .idle

        return Text(text)
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(show ? .blue : .clear)
            .frame(maxWidth: .infinity, minHeight: 64)
    }

    private func elapsedText() -> String {
        switch phase {
        case .idle:
            return "0.0 秒"
        case .startToRechaka:
            return "\(truncate1(elapsed(from: startedAt))) 秒"
        case .waitPuraakaStart:
            return "0.0 秒"
        case .puraakaRunning:
            return "\(truncate1(elapsed(from: puraakaAt))) 秒"
        }
    }

    private func elapsed(from base: Date?) -> Double {
        guard let base else { return 0 }
        return max(0, now.timeIntervalSince(base))
    }

    // MARK: - Actions

    private func handleStartButton() {
        if phase == .idle {
            startRechakaPhase()
        } else if phase == .waitPuraakaStart {
            startPuraakaPhaseManually()
        }
    }

    private func startRechakaPhase() {
        let t = Date()
        startedAt = t
        lastRechaka = nil
        lastPuraaka = nil
        rechakaAt = nil
        puraakaAt = nil
        now = t
        phase = .startToRechaka
    }

    // レーチャカ停止（=最初の区間の記録）
    private func rechakaStop() {
        guard let startedAt else { return }
        let t = Date()

        lastRechaka = t.timeIntervalSince(startedAt)
        now = t

        switch rechakaStartMode {
        case .auto:
            puraakaAt = t
            phase = .puraakaRunning
        case .manual:
            puraakaAt = nil
            phase = .waitPuraakaStart
        }
    }

    private func startPuraakaPhaseManually() {
        let t = Date()
        puraakaAt = t
        now = t
        phase = .puraakaRunning
    }

    // プーラカ停止（=2つ目の区間の記録）→ 保存して終了
    private func finishPuraakaAndSave() {
        guard let startedAt, let puraakaAt else { return }
        let t = Date()

        lastPuraaka = t.timeIntervalSince(puraakaAt)
        now = t

        // 保存（record1=レーチャカ、record2=プーラカ）
        let session = SessionRecord(startedAt: startedAt)
        session.record1Seconds = lastRechaka
        session.record2Seconds = lastPuraaka
        session.endedAt = t
        modelContext.insert(session)

        lastCompletedStartedAt = startedAt
        phase = .idle
    }

    // MARK: - Stability

    private func stabilityLoop() async {
        lastTick = Date()
        stableSince = nil
        isReady = false

        while !Task.isCancelled {
            let t = Date()
            let dt = t.timeIntervalSince(lastTick)
            lastTick = t
            now = t

            if !isReady {
                if dt > hangThreshold {
                    stableSince = nil
                } else {
                    if stableSince == nil { stableSince = t }
                    if let s = stableSince, t.timeIntervalSince(s) >= requiredStable {
                        isReady = true
                    }
                }
            }
            try? await Task.sleep(nanoseconds: tickInterval)
        }
    }

    // MARK: - Formatting

    private func truncate1(_ v: Double) -> String {
        String(format: "%.1f", floor(v * 10) / 10)
    }

    private func simpleResultRow(title: String, value: Double?, titleColor: Color) -> some View {
        HStack {
            Text(title)
                .fontWeight(.bold)
                .foregroundColor(titleColor)
            Spacer()
            Text(Self.formatTime(value, style: timeDisplayStyle))
                .monospacedDigit()
                .foregroundColor(.black)
        }
    }

    private func playTapSound() {
        AudioServicesPlaySystemSound(1104)
    }

    private func bigButton(title: String, enabled: Bool, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(enabled ? background : .gray.opacity(0.35))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .disabled(!enabled)
    }
}

// MARK: - History（表示形式だけ反映）

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]

    @AppStorage("timeDisplayStyle") private var timeDisplayStyleRaw: String = TimeDisplayStyle.minuteSecond.rawValue
    private var timeDisplayStyle: TimeDisplayStyle {
        TimeDisplayStyle(rawValue: timeDisplayStyleRaw) ?? .minuteSecond
    }

    private var groupedDays: [(day: Date, items: [SessionRecord])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startedAt) }
        let days = dict.keys.sorted(by: >)
        return days.map { day in
            let items = (dict[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            return (day, items)
        }
    }

    var body: some View {
        List {
            ForEach(groupedDays, id: \.day) { section in
                Section {
                    ForEach(section.items) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ContentView.timeOnly.string(from: s.startedAt))
                                    .font(.headline)
                                Text("レーチャカ: \(ContentView.formatTime(s.record1Seconds, style: timeDisplayStyle)) / プーラカ: \(ContentView.formatTime(s.record2Seconds, style: timeDisplayStyle))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            ShareLink(item: shareText(for: s)) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(.thinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            modelContext.delete(section.items[i])
                        }
                    }
                } header: {
                    headerView(for: section.day, items: section.items)
                }
            }
        }
        .navigationTitle("履歴")
    }

    private func headerView(for day: Date, items: [SessionRecord]) -> some View {
        HStack(spacing: 12) {
            Text(ContentView.dateOnly.string(from: day))
                .font(.headline)

            Spacer()

            ShareLink(item: shareTextForDay(day: day, sessions: items)) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                    Text("この日を共有")
                        .font(.headline)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    private func shareText(for s: SessionRecord) -> String {
        """
        開始: \(ContentView.df.string(from: s.startedAt))
        レーチャカ: \(ContentView.formatTime(s.record1Seconds, style: timeDisplayStyle))
        プーラカ: \(ContentView.formatTime(s.record2Seconds, style: timeDisplayStyle))
        """
    }

    private func shareTextForDay(day: Date, sessions: [SessionRecord]) -> String {
        var lines: [String] = []
        lines.append(ContentView.dateOnly.string(from: day))
        lines.append("")

        for s in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            lines.append("開始: \(ContentView.timeOnly.string(from: s.startedAt))")
            lines.append("レーチャカ: \(ContentView.formatTime(s.record1Seconds, style: timeDisplayStyle))")
            lines.append("プーラカ: \(ContentView.formatTime(s.record2Seconds, style: timeDisplayStyle))")
            lines.append("")
        }

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - DateFormatter / 共通フォーマッタ

extension ContentView {
    static let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd H:mm:ss"
        return f
    }()

    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm:ss"
        return f
    }()

    static func formatTime(_ seconds: Double?, style: TimeDisplayStyle) -> String {
        guard let s = seconds else { return "—" }

        switch style {
        case .decimalSecond:
            let v = floor(s * 10) / 10
            return String(format: "%.1f 秒", v)

        case .minuteSecond:
            let total = Int(s) // 秒以下は切り捨て
            let m = total / 60
            let sec = total % 60
            if m > 0 {
                return "\(m)分\(sec)秒"
            } else {
                return "\(sec)秒"
            }
        }
    }
}
