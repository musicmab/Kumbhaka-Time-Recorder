import SwiftUI
import SwiftData
import Combine
import AudioToolbox

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]

    // 進行中セッション
    @State private var currentSession: SessionRecord?

    // 計測基準時刻
    @State private var startDate: Date?
    @State private var record1Date: Date?

    // 秒数表示モード
    private enum DisplayMode {
        case none
        case startToR1      // スタート → プーラカ
        case r1ToR2         // プーラカ → レーチャカ
    }
    @State private var displayMode: DisplayMode = .none

    // 直近の確定値
    @State private var lastMeasured1: Double?
    @State private var lastMeasured2: Double?

    // 表示用タイマー
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                // ===== 秒数表示領域（常に高さ確保）=====
                elapsedHeader
                    .onReceive(ticker) { now = $0 }

                // ===== 操作ボタン =====
                VStack(spacing: 14) {

                    bigButton(
                        title: "スタート",
                        enabled: !isRunning,
                        background: .blue
                    ) {
                        playTapSound()
                        startSession()
                    }

                    bigButton(
                        title: "プーラカ",
                        enabled: canRecord1,
                        background: .green
                    ) {
                        playTapSound()
                        tapRecord1()
                    }

                    bigButton(
                        title: "レーチャカ",
                        enabled: canRecord2,
                        background: .orange
                    ) {
                        playTapSound()
                        tapRecord2()
                    }
                }

                // ===== シンプルな結果表示 =====
                VStack(spacing: 8) {
                    simpleResultRow(title: "プーラカ", value: lastMeasured1)
                    simpleResultRow(title: "レーチャカ", value: lastMeasured2)
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // ===== 履歴 =====
                List {
                    Section("セッション履歴") {
                        ForEach(sessions) { s in
                            NavigationLink {
                                SessionDetailView(session: s)
                            } label: {
                                sessionRow(s)
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
                .listStyle(.insetGrouped)

            }
            .padding()
        }
    }

    // MARK: - Header（常にスペース確保）

    private var elapsedHeader: some View {
        let text = elapsedText()
        return Text(text)
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(displayMode == .none ? .clear : .blue)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
    }

    private func elapsedText() -> String {
        switch displayMode {
        case .none:
            return "0.0 秒"   // 高さ確保用
        case .startToR1:
            return String(format: "%.1f 秒", elapsedFrom(startDate))
        case .r1ToR2:
            return String(format: "%.1f 秒", elapsedFrom(record1Date))
        }
    }

    private func elapsedFrom(_ base: Date?) -> Double {
        guard let base else { return 0.0 }
        return max(0.0, now.timeIntervalSince(base))
    }

    // MARK: - UI Parts

    private func bigButton(
        title: String,
        enabled: Bool,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(enabled ? background : .gray.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .disabled(!enabled)
    }

    private func simpleResultRow(title: String, value: Double?) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(formatSeconds(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func sessionRow(_ s: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(formatDateTime(s.startedAt))
                .font(.headline)

            Text("プーラカ: \(formatSeconds(s.record1Seconds))    レーチャカ: \(formatSeconds(s.record2Seconds))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State

    private var isRunning: Bool { currentSession != nil }

    private var canRecord1: Bool {
        isRunning && currentSession?.record1Seconds == nil
    }

    private var canRecord2: Bool {
        isRunning &&
        currentSession?.record1Seconds != nil &&
        currentSession?.record2Seconds == nil
    }

    // MARK: - Actions

    private func startSession() {
        let startedAt = Date()
        let session = SessionRecord(startedAt: startedAt)
        modelContext.insert(session)

        currentSession = session
        startDate = startedAt
        record1Date = nil

        lastMeasured1 = nil
        lastMeasured2 = nil

        displayMode = .startToR1
        now = Date()
    }

    private func tapRecord1() {
        guard let session = currentSession, let startDate else { return }

        let t = Date()
        let seconds = t.timeIntervalSince(startDate)

        session.record1Seconds = seconds
        lastMeasured1 = seconds

        record1Date = t
        displayMode = .r1ToR2
        now = t
    }

    private func tapRecord2() {
        guard let session = currentSession, let record1Date else { return }

        let t = Date()
        let seconds = t.timeIntervalSince(record1Date)

        session.record2Seconds = seconds
        session.endedAt = t
        lastMeasured2 = seconds

        currentSession = nil
        startDate = nil
        self.record1Date = nil

        now = t
    }

    private func deleteSessions(at offsets: IndexSet) {
        for i in offsets {
            modelContext.delete(sessions[i])
        }
    }

    // MARK: - Sound

    private func playTapSound() {
        AudioServicesPlaySystemSound(1104)
    }

    // MARK: - Formatting

    private func formatSeconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f 秒", value)
    }

    private func formatDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }
}

struct SessionDetailView: View {
    let session: SessionRecord

    var body: some View {
        List {
            Section("開始") {
                Text(formatDateTime(session.startedAt))
            }

            Section("記録") {
                row("プーラカ", session.record1Seconds)
                row("レーチャカ", session.record2Seconds)
            }

            Section("終了") {
                Text(session.endedAt.map { formatDateTime($0) } ?? "—")
            }
        }
    }

    private func row(_ title: String, _ seconds: Double?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formatSeconds(seconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func formatSeconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f 秒", value)
    }

    private func formatDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }
}

