import SwiftUI
import SwiftData
import AudioToolbox

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    // ===== 安定するまで false =====
    @State private var isReady = false

    // 安定判定用
    @State private var lastTick: Date = Date()
    @State private var stableSince: Date? = nil

    // チューニング可能
    private let tickInterval: UInt64 = 100_000_000       // 0.1s
    private let hangThreshold: TimeInterval = 0.25       // 0.25s を超えたら “固まり”
    private let requiredStable: TimeInterval = 2.0       // 2秒安定したら ready

    // 計測状態（SwiftDataではなくメモリ）
    private enum Phase { case idle, startToPuraaka, puraakaToRechaka }
    @State private var phase: Phase = .idle

    @State private var startedAt: Date?
    @State private var puraakaAt: Date?

    @State private var lastPuraaka: Double?
    @State private var lastRechaka: Double?

    // 表示更新
    @State private var now: Date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                elapsedHeader

                VStack(spacing: 14) {
                    bigButton(
                        title: "スタート",
                        enabled: isReady && phase == .idle,
                        background: .blue
                    ) {
                        playTapSound()
                        start()
                    }

                    bigButton(
                        title: "プーラカ",
                        enabled: isReady && phase == .startToPuraaka,
                        background: .green
                    ) {
                        playTapSound()
                        puraaka()
                    }

                    bigButton(
                        title: "レーチャカ",
                        enabled: isReady && phase == .puraakaToRechaka,
                        background: .orange
                    ) {
                        playTapSound()
                        rechakaAndSave()
                    }
                }

                VStack(spacing: 8) {
                    simpleResultRow(title: "プーラカ", value: lastPuraaka)
                    simpleResultRow(title: "レーチャカ", value: lastRechaka)
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                NavigationLink {
                    HistoryView()
                } label: {
                    Text("履歴を見る")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!isReady)
                .opacity(isReady ? 1.0 : 0.6)

                Spacer(minLength: 0)

                if !isReady {
                    Text("準備中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .task {
                // 安定検知ループ
                lastTick = Date()
                stableSince = nil
                isReady = false

                while !Task.isCancelled {
                    let t = Date()
                    let dt = t.timeIntervalSince(lastTick)
                    lastTick = t

                    // now は常に更新（計測中は表示に使う）
                    now = t

                    // まだ ready でない間だけ安定判定する（ready後は不要）
                    if !isReady {
                        if dt > hangThreshold {
                            // “固まり”が起きた → 安定判定リセット
                            stableSince = nil
                        } else {
                            // 固まりなし
                            if stableSince == nil { stableSince = t }
                            if let s = stableSince, t.timeIntervalSince(s) >= requiredStable {
                                isReady = true
                            }
                        }
                    }

                    try? await Task.sleep(nanoseconds: tickInterval)
                }
            }
        }
    }

    // MARK: - Header（準備中もスペース確保、readyまで固定）

    private var elapsedHeader: some View {
        // 準備中は “0.0秒” を透明表示で固定してチラつきを抑える
        let text = isReady ? elapsedText() : "0.0 秒"

        return Text(text)
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor((isReady && phase != .idle) ? .blue : .clear)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
    }

    private func elapsedText() -> String {
        switch phase {
        case .idle:
            return "0.0 秒"
        case .startToPuraaka:
            return String(format: "%.1f 秒", elapsed(from: startedAt))
        case .puraakaToRechaka:
            return String(format: "%.1f 秒", elapsed(from: puraakaAt))
        }
    }

    private func elapsed(from base: Date?) -> Double {
        guard let base else { return 0.0 }
        return max(0.0, now.timeIntervalSince(base))
    }

    // MARK: - Actions（スタート時にSwiftDataを触らない）

    private func start() {
        let t = Date()
        startedAt = t
        puraakaAt = nil
        lastPuraaka = nil
        lastRechaka = nil
        now = t
        phase = .startToPuraaka
    }

    private func puraaka() {
        guard let startedAt else { return }
        let t = Date()
        let sec = t.timeIntervalSince(startedAt)
        lastPuraaka = sec
        puraakaAt = t
        now = t
        phase = .puraakaToRechaka
    }

    private func rechakaAndSave() {
        guard let startedAt, let puraakaAt else { return }
        let t = Date()
        let rechakaSec = t.timeIntervalSince(puraakaAt)
        lastRechaka = rechakaSec
        now = t

        // 保存は最後に1回だけ
        let session = SessionRecord(startedAt: startedAt)
        session.record1Seconds = lastPuraaka
        session.record2Seconds = lastRechaka
        session.endedAt = t
        modelContext.insert(session)

        self.startedAt = nil
        self.puraakaAt = nil
        phase = .idle
    }

    // MARK: - UI

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
            Text(title).font(.headline)
            Spacer()
            Text(formatSeconds(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func playTapSound() {
        AudioServicesPlaySystemSound(1104)
    }

    private func formatSeconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f 秒", value)
    }
}

// MARK: - History（@QueryとListを隔離）

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]

    var body: some View {
        List {
            ForEach(sessions) { s in
                NavigationLink {
                    SessionDetailView(session: s)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ContentView.df.string(from: s.startedAt))
                            .font(.headline)
                        Text("プーラカ: \(fmt(s.record1Seconds))    レーチャカ: \(fmt(s.record2Seconds))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { modelContext.delete(sessions[i]) }
            }
        }
        .navigationTitle("履歴")
    }

    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.3f 秒", v)
    }
}

struct SessionDetailView: View {
    let session: SessionRecord

    var body: some View {
        List {
            Section("開始") { Text(ContentView.df.string(from: session.startedAt)) }
            Section("記録") {
                row("プーラカ", session.record1Seconds)
                row("レーチャカ", session.record2Seconds)
            }
            Section("終了") {
                Text(session.endedAt.map { ContentView.df.string(from: $0) } ?? "—")
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
}

// DateFormatter共有
extension ContentView {
    static let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
}
