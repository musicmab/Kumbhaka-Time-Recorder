import SwiftUI
import SwiftData
import Combine
import AudioToolbox

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]

    // 進行中セッション
    @State private var currentSession: SessionRecord?

    @State private var startDate: Date?
    @State private var record1Date: Date?

    @State private var lastMeasured1: Double?
    @State private var lastMeasured2: Double?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                // ===== 大きな操作ボタン =====
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
                        title: "記録1",
                        enabled: canRecord1,
                        background: .green
                    ) {
                        playTapSound()
                        tapRecord1()
                    }

                    bigButton(
                        title: "記録2",
                        enabled: canRecord2,
                        background: .orange
                    ) {
                        playTapSound()
                        tapRecord2()
                    }
                }

                // ===== 計測結果 =====
                VStack(alignment: .leading, spacing: 10) {
                    Text("直近の計測結果")
                        .font(.headline)

                    resultRow("記録1（スタート→記録1）", lastMeasured1)
                    resultRow("記録2（記録1→記録2）", lastMeasured2)
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
            .navigationTitle("秒数記録")
        }
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

    private func resultRow(_ title: String, _ value: Double?) -> some View {
        HStack {
            Text(title)
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

            Text("記録1: \(formatSeconds(s.record1Seconds))    記録2: \(formatSeconds(s.record2Seconds))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State

    private var isRunning: Bool {
        currentSession != nil
    }

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
    }

    private func tapRecord1() {
        guard let session = currentSession, let startDate else { return }
        let t = Date()
        let seconds = t.timeIntervalSince(startDate)

        session.record1Seconds = seconds
        record1Date = t
        lastMeasured1 = seconds
    }

    private func tapRecord2() {
        guard let session = currentSession, let record1Date else { return }
        let t = Date()
        let seconds = t.timeIntervalSince(record1Date)

        session.record2Seconds = seconds
        session.endedAt = t
        lastMeasured2 = seconds

        // セッション終了
        currentSession = nil
        startDate = nil
        self.record1Date = nil
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
                row("記録1（スタート→記録1）", session.record1Seconds)
                row("記録2（記録1→記録2）", session.record2Seconds)
            }

            Section("終了") {
                Text(session.endedAt.map { formatDateTime($0) } ?? "—")
            }
        }
        .navigationTitle("セッション詳細")
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

