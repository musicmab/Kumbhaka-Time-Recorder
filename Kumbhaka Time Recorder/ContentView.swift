import SwiftUI
import SwiftData
import AudioToolbox

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    // 設定（永続）
    @AppStorage("rechakaStartMode") private var rechakaStartModeRaw: String = RechakaStartMode.auto.rawValue
    private var rechakaStartMode: RechakaStartMode {
        RechakaStartMode(rawValue: rechakaStartModeRaw) ?? .auto
    }

    // ===== 安定するまで false =====
    @State private var isReady = false
    @State private var lastTick: Date = Date()
    @State private var stableSince: Date? = nil

    private let tickInterval: UInt64 = 100_000_000
    private let hangThreshold: TimeInterval = 0.25
    private let requiredStable: TimeInterval = 2.0

    // ===== フェーズ =====
    private enum Phase {
        case idle
        case startToPuraaka
        case waitRechakaStart
        case rechakaRunning
    }
    @State private var phase: Phase = .idle

    // ===== 時刻 =====
    @State private var startedAt: Date?
    @State private var puraakaAt: Date?
    @State private var rechakaAt: Date?

    // ===== 直近完了セッション（共有用） =====
    @State private var lastCompletedStartedAt: Date?

    // ===== 結果 =====
    @State private var lastPuraaka: Double?
    @State private var lastRechaka: Double?

    @State private var now: Date = Date()

    // MARK: - Button Titles

    private var startButtonTitle: String {
        switch rechakaStartMode {
        case .auto:
            return "スタート"
        case .manual:
            switch phase {
            case .idle: return "プーラカスタート"
            case .waitRechakaStart: return "レーチャカスタート"
            default: return "スタート"
            }
        }
    }

    private var puraakaButtonTitle: String {
        rechakaStartMode == .manual ? "プーラカストップ" : "プーラカ"
    }

    private var rechakaButtonTitle: String {
        rechakaStartMode == .manual ? "レーチャカストップ" : "レーチャカ"
    }

    private var canTapStart: Bool {
        phase == .idle || phase == .waitRechakaStart
    }

    // MARK: - メイン共有（簡易文面）

    private var canShareFromMain: Bool {
        lastCompletedStartedAt != nil && lastPuraaka != nil && lastRechaka != nil
    }

    private var mainShareText: String {
        let started = lastCompletedStartedAt.map { Self.df.string(from: $0) } ?? "—"
        return """
        開始: \(started)
        プーラカ: \(formatSeconds(lastPuraaka))
        レーチャカ: \(formatSeconds(lastRechaka))
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
                        title: puraakaButtonTitle,
                        enabled: isReady && phase == .startToPuraaka,
                        background: .green
                    ) {
                        playTapSound()
                        puraaka()
                    }

                    bigButton(
                        title: rechakaButtonTitle,
                        enabled: isReady && phase == .rechakaRunning,
                        background: .orange
                    ) {
                        playTapSound()
                        finishRechakaAndSave()
                    }
                }

                VStack(spacing: 8) {
                    simpleResultRow(title: "プーラカ", value: lastPuraaka)
                    simpleResultRow(title: "レーチャカ", value: lastRechaka)
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

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

    // MARK: - Header

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
        case .startToPuraaka:
            return "\(truncate1(elapsed(from: startedAt))) 秒"
        case .waitRechakaStart:
            return "0.0 秒"
        case .rechakaRunning:
            return "\(truncate1(elapsed(from: rechakaAt))) 秒"
        }
    }

    private func elapsed(from base: Date?) -> Double {
        guard let base else { return 0 }
        return max(0, now.timeIntervalSince(base))
    }

    // MARK: - Actions

    private func handleStartButton() {
        if phase == .idle {
            startPuraakaPhase()
        } else if phase == .waitRechakaStart {
            startRechakaPhaseManually()
        }
    }

    private func startPuraakaPhase() {
        let t = Date()
        startedAt = t
        lastPuraaka = nil
        lastRechaka = nil
        now = t
        phase = .startToPuraaka
    }

    private func puraaka() {
        guard let startedAt else { return }
        let t = Date()
        lastPuraaka = t.timeIntervalSince(startedAt)
        puraakaAt = t
        now = t

        if rechakaStartMode == .auto {
            rechakaAt = t
            phase = .rechakaRunning
        } else {
            phase = .waitRechakaStart
        }
    }

    private func startRechakaPhaseManually() {
        let t = Date()
        rechakaAt = t
        now = t
        phase = .rechakaRunning
    }

    private func finishRechakaAndSave() {
        guard let startedAt, let rechakaAt else { return }
        let t = Date()
        lastRechaka = t.timeIntervalSince(rechakaAt)

        let session = SessionRecord(startedAt: startedAt)
        session.record1Seconds = lastPuraaka
        session.record2Seconds = lastRechaka
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

    // MARK: - Formatting（切り捨て小数1桁）

    private func truncate1(_ v: Double) -> String {
        String(format: "%.1f", floor(v * 10) / 10)
    }

    private func formatSeconds(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(truncate1(v)) 秒"
    }

    // MARK: - UI

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

    private func simpleResultRow(title: String, value: Double?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formatSeconds(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func playTapSound() {
        AudioServicesPlaySystemSound(1104)
    }
}

// MARK: - History（日付グループ化＋日付共有：ボタン大型化／開始は時刻のみ／日付下に1行空ける）

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]

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
                                Text("プーラカ: \(fmt(s.record1Seconds)) / レーチャカ: \(fmt(s.record2Seconds))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            // 個別共有（開始は日付込み）
                            ShareLink(item: shareText(for: s)) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(.thinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("この記録を共有")
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

    // セクションヘッダー（共有ボタン大型化）
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
            .accessibilityLabel("この日の履歴を共有")
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    // 小数1桁切り捨て表示
    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        let t = floor(v * 10) / 10
        return String(format: "%.1f 秒", t)
    }

    // 個別共有（指定フォーマット：開始は日付＋時刻）
    private func shareText(for s: SessionRecord) -> String {
        """
        開始: \(ContentView.df.string(from: s.startedAt))
        プーラカ: \(fmt(s.record1Seconds))
        レーチャカ: \(fmt(s.record2Seconds))
        """
    }

    // 日付共有（各セッションの「開始」は時刻のみ：日付は省略／日付下に1行空ける）
    private func shareTextForDay(day: Date, sessions: [SessionRecord]) -> String {
        var lines: [String] = []
        lines.append(ContentView.dateOnly.string(from: day))
        lines.append("") // ★ 日付の下を1行空ける

        for s in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            lines.append("開始: \(ContentView.timeOnly.string(from: s.startedAt))")
            lines.append("プーラカ: \(fmt(s.record1Seconds))")
            lines.append("レーチャカ: \(fmt(s.record2Seconds))")
            lines.append("")
        }

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - DateFormatter共有

extension ContentView {
    // 個別共有は「開始: yyyy/MM/dd H:mm:ss」
    static let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd H:mm:ss"
        return f
    }()

    // 履歴セクション用（日付だけ）
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    // 履歴行・日付共有の開始表示用（時刻だけ）
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm:ss"
        return f
    }()
}
