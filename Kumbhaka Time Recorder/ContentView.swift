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

    // 安定判定用
    @State private var lastTick: Date = Date()
    @State private var stableSince: Date? = nil

    // チューニング可能
    private let tickInterval: UInt64 = 100_000_000       // 0.1s
    private let hangThreshold: TimeInterval = 0.25       // 0.25sを超えたら“固まり”
    private let requiredStable: TimeInterval = 2.0       // 2秒安定でready

    // ===== フェーズ =====
    private enum Phase {
        case idle                    // 未開始
        case startToPuraaka          // プーラカ計測中
        case waitRechakaStart        // （手動）レーチャカ開始待ち
        case rechakaRunning          // レーチャカ計測中
    }
    @State private var phase: Phase = .idle

    // ===== 時刻 =====
    @State private var startedAt: Date?
    @State private var puraakaAt: Date?
    @State private var rechakaAt: Date?

    // ===== 結果 =====
    @State private var lastPuraaka: Double?
    @State private var lastRechaka: Double?

    // 表示更新
    @State private var now: Date = Date()

    // MARK: - Button Titles

    // スタートボタン（手動方式では文言を変える）
    private var startButtonTitle: String {
        switch rechakaStartMode {
        case .auto:
            return "スタート"
        case .manual:
            switch phase {
            case .idle:
                return "プーラカスタート"
            case .waitRechakaStart:
                return "レーチャカスタート"
            default:
                return "スタート"
            }
        }
    }

    // ★今回の変更：手動方式のときだけ「ストップ」表記にする
    private var puraakaButtonTitle: String {
        (rechakaStartMode == .manual) ? "プーラカストップ" : "プーラカ"
    }

    private var rechakaButtonTitle: String {
        (rechakaStartMode == .manual) ? "レーチャカストップ" : "レーチャカ"
    }

    // MARK: - Start Button Enabled

    private var canTapStart: Bool {
        switch phase {
        case .idle:
            return true
        case .waitRechakaStart:
            return true
        default:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {

                // 秒数表示（常に領域確保）
                elapsedHeader

                // ボタン群
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

                // 結果（最小表示）
                VStack(spacing: 8) {
                    simpleResultRow(title: "プーラカ", value: lastPuraaka)
                    simpleResultRow(title: "レーチャカ", value: lastRechaka)
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // 履歴 / 設定
                HStack(spacing: 12) {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Text("履歴")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!isReady)
                    .opacity(isReady ? 1.0 : 0.6)

                    NavigationLink {
                        SettingsView()
                    } label: {
                        Text("設定")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!isReady)
                    .opacity(isReady ? 1.0 : 0.6)
                }

                Spacer(minLength: 0)

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
        // 準備中は固定してチラつきを抑える
        let text = isReady ? elapsedText() : "0.0 秒"
        let show = isReady && phase != .idle

        return Text(text)
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(show ? .blue : .clear)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
    }

    private func elapsedText() -> String {
        switch phase {
        case .idle:
            return "0.0 秒"
        case .startToPuraaka:
            return String(format: "%.1f 秒", elapsed(from: startedAt))
        case .waitRechakaStart:
            // 待機中は0表示（表示領域は維持）
            return "0.0 秒"
        case .rechakaRunning:
            return String(format: "%.1f 秒", elapsed(from: rechakaAt))
        }
    }

    private func elapsed(from base: Date?) -> Double {
        guard let base else { return 0.0 }
        return max(0.0, now.timeIntervalSince(base))
    }

    // MARK: - Actions

    private func handleStartButton() {
        switch phase {
        case .idle:
            startPuraakaPhase()
        case .waitRechakaStart:
            startRechakaPhaseManually()
        default:
            break
        }
    }

    private func startPuraakaPhase() {
        let t = Date()
        startedAt = t
        puraakaAt = nil
        rechakaAt = nil
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

        switch rechakaStartMode {
        case .auto:
            // 自動：即レーチャカ開始
            rechakaAt = t
            phase = .rechakaRunning

        case .manual:
            // 手動：レーチャカ開始待ち（スタート再有効化）
            rechakaAt = nil
            phase = .waitRechakaStart
        }
    }

    private func startRechakaPhaseManually() {
        // 手動モードでのみ到達
        let t = Date()
        rechakaAt = t
        now = t
        phase = .rechakaRunning
    }

    private func finishRechakaAndSave() {
        guard let startedAt, let puraakaAt, let rechakaAt else { return }

        let t = Date()
        let rechakaSec = t.timeIntervalSince(rechakaAt)

        lastRechaka = rechakaSec
        now = t

        // 保存（最後に1回だけ）
        let session = SessionRecord(startedAt: startedAt)
        session.record1Seconds = lastPuraaka
        session.record2Seconds = lastRechaka
        session.endedAt = t
        modelContext.insert(session)

        // リセット
        self.startedAt = nil
        self.puraakaAt = nil
        self.rechakaAt = nil
        phase = .idle
    }

    // MARK: - Stability Loop (Ready gating)

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

    // MARK: - UI parts

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
                for i in offsets {
                    modelContext.delete(sessions[i])
                }
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
