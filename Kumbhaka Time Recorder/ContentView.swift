// ContentView.swift
import SwiftUI
import SwiftData
import AudioToolbox
import AVFoundation

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

// 目標達成時の強調色（設定用）
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

    // ✅ 今日分の履歴（自前で fetch）
    @State private var todaySessions: [SessionRecord] = []

    // 設定（永続）
    @AppStorage("rechakaStartMode") private var rechakaStartModeRaw: String = RechakaStartMode.auto.rawValue
    private var rechakaStartMode: RechakaStartMode {
        RechakaStartMode(rawValue: rechakaStartModeRaw) ?? .auto
    }

    // 表示形式
    @AppStorage("timeDisplayStyle") private var timeDisplayStyleRaw: String = TimeDisplayStyle.minuteSecond.rawValue
    private var timeDisplayStyle: TimeDisplayStyle {
        TimeDisplayStyle(rawValue: timeDisplayStyleRaw) ?? .minuteSecond
    }

    // 目標（秒）と強調色
    @AppStorage("goalSeconds") private var goalSeconds: Double = 0.0
    @AppStorage("goalHighlightColor") private var goalColorRaw: String = GoalHighlightColor.red.rawValue
    private var goalColor: Color {
        (GoalHighlightColor(rawValue: goalColorRaw) ?? .red).color
    }

    // 今日の記録：削除確認用
    @State private var sessionPendingDelete: SessionRecord? = nil
    @State private var showDeleteAlert: Bool = false

    // 準備中 点滅用
    @State private var isPreparingBlink = false

    // ===== 安定するまで false =====
    @State private var isReady = false
    @State private var lastTick: Date = Date()
    @State private var stableSince: Date? = nil

    private let tickInterval: UInt64 = 100_000_000 // 0.1s
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
    @State private var puraakaAt: Date?

    // ===== 直近完了セッション（共有用） =====
    @State private var lastCompletedStartedAt: Date?

    // ===== 結果（表示は レーチャカ→プーラカ の順）=====
    @State private var lastRechaka: Double?
    @State private var lastPuraaka: Double?

    @State private var now: Date = Date()

    // ===== 10秒ごとのアナウンス =====
    @State private var lastAnnouncedBucketRechaka: Int = -1
    @State private var lastAnnouncedBucketPuraaka: Int = -1

    // ✅ 音声初期化は一度だけ
    @State private var didPrepareSpeech: Bool = false

    // ✅ 日付跨ぎ監視タスク
    @State private var midnightTask: Task<Void, Never>? = nil

    // 読み上げ
    private let announcer = AVSpeechSynthesizer()

    // MARK: - 目標達成回数（今日・レーチャカのみ）
    private var goalAchievedCountToday: Int {
        guard goalSeconds > 0 else { return 0 }
        return todaySessions.reduce(0) { acc, s in
            let r1 = s.record1Seconds ?? 0
            return acc + ((r1 >= goalSeconds) ? 1 : 0)
        }
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

                // ✅ 秒表示（画面中央固定）＋共有（右端）
                ZStack {
                    elapsedHeader
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Spacer()
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
                }

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

                    // ✅ 準備中（上段のみ、青、ゆっくり点滅）
                    if !isReady {
                        Text("準備中")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .opacity(isPreparingBlink ? 0.25 : 1.0)
                            .padding(.top, 4)
                            .onAppear {
                                isPreparingBlink = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                                        isPreparingBlink = true
                                    }
                                }
                            }
                            .onChange(of: isReady) { _, newValue in
                                if newValue { isPreparingBlink = false }
                            }
                    }
                }

                // 直近結果
                VStack(spacing: 8) {
                    simpleResultRow(title: "レーチャカ", value: lastRechaka, titleColor: .orange)
                    simpleResultRow(title: "プーラカ", value: lastPuraaka, titleColor: .green)
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // 今日分の履歴
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
            }
            .padding()
            .task {
                // 起動時に今日分を取得
                await MainActor.run { fetchTodaySessions() }

                // 日付跨ぎ監視（多重起動防止）
                midnightTask?.cancel()
                midnightTask = Task { await startMidnightWatcher() }

                // 安定化ループ
                await stabilityLoop()
            }
            .onDisappear {
                midnightTask?.cancel()
                midnightTask = nil
            }
        }
    }

    // MARK: - 今日分の取得（日付跨ぎ対応）

    @MainActor
    private func fetchTodaySessions() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)

        let predicate = #Predicate<SessionRecord> { s in
            s.startedAt >= start && s.startedAt < end
        }

        let desc = FetchDescriptor<SessionRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )

        do {
            todaySessions = try modelContext.fetch(desc)
        } catch {
            todaySessions = []
        }
    }

    private func startMidnightWatcher() async {
        while !Task.isCancelled {
            let cal = Calendar.current
            let now = Date()
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            let seconds = tomorrowStart.timeIntervalSince(now)

            let ns = UInt64(max(1, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)

            await MainActor.run {
                fetchTodaySessions()
            }
        }
    }

    // MARK: - 今日分履歴パネル（均等ヘッダー + 目標達成回数）

    private var todayHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ✅ ここが「均等に開ける」ヘッダー
            HStack {
                // 左
                Text("今日の記録")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 中央
                Text("\(todaySessions.count)件")
                    .font(.subheadline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .center)

                // 右（目標設定時のみ表示、未設定時はダミーで幅を揃える）
                if goalSeconds > 0 {
                    Text("目標達成 \(goalAchievedCountToday)回")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                }
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

                    Spacer().frame(width: 24)

                    Text("レーチャカ")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("プーラカ")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("")
                        .frame(width: 36)
                }
                .padding(.top, 2)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(todaySessions) { s in
                            let r1 = s.record1Seconds
                            let r2 = s.record2Seconds

                            HStack(spacing: 10) {
                                Text(Self.timeOnly.string(from: s.startedAt))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.black)
                                    .frame(width: 80, alignment: .center)

                                Spacer().frame(width: 24)

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

                                // ✅ 個別削除（目立たないグレー）
                                Button {
                                    sessionPendingDelete = s
                                    showDeleteAlert = true
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 8)
                                        .background(.thinMaterial)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("削除")
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
        .alert("この記録を削除しますか？", isPresented: $showDeleteAlert) {
            Button("削除", role: .destructive) {
                if let target = sessionPendingDelete {
                    modelContext.delete(target)
                }
                sessionPendingDelete = nil
                fetchTodaySessions()
            }
            Button("キャンセル", role: .cancel) {
                sessionPendingDelete = nil
            }
        } message: {
            if let target = sessionPendingDelete {
                Text("\(Self.timeOnly.string(from: target.startedAt)) の記録を削除します。")
            } else {
                Text("この記録を削除します。")
            }
        }
    }

    private func colorForGoal(_ seconds: Double?) -> Color {
        guard goalSeconds > 0 else { return .black }
        guard let s = seconds else { return .black }
        return (s >= goalSeconds) ? goalColor : .black
    }

    // MARK: - Header（経過表示は小数1位秒）

    private var elapsedHeader: some View {
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
        prepareSpeechIfNeeded()

        let t = Date()
        startedAt = t
        lastRechaka = nil
        lastPuraaka = nil
        puraakaAt = nil
        now = t
        phase = .startToRechaka

        lastAnnouncedBucketRechaka = -1
        if announcer.isSpeaking { announcer.stopSpeaking(at: .immediate) }
    }

    private func rechakaStop() {
        guard let startedAt else { return }
        let t = Date()
        lastRechaka = t.timeIntervalSince(startedAt)
        now = t

        switch rechakaStartMode {
        case .auto:
            puraakaAt = t
            lastAnnouncedBucketPuraaka = -1
            if announcer.isSpeaking { announcer.stopSpeaking(at: .immediate) }
            phase = .puraakaRunning

        case .manual:
            puraakaAt = nil
            if announcer.isSpeaking { announcer.stopSpeaking(at: .immediate) }
            phase = .waitPuraakaStart
        }
    }

    private func startPuraakaPhaseManually() {
        prepareSpeechIfNeeded()

        let t = Date()
        puraakaAt = t
        now = t
        phase = .puraakaRunning

        lastAnnouncedBucketPuraaka = -1
        if announcer.isSpeaking { announcer.stopSpeaking(at: .immediate) }
    }

    private func finishPuraakaAndSave() {
        guard let startedAt, let puraakaAt else { return }
        let t = Date()

        lastPuraaka = t.timeIntervalSince(puraakaAt)
        now = t

        let session = SessionRecord(startedAt: startedAt)
        session.record1Seconds = lastRechaka
        session.record2Seconds = lastPuraaka
        session.endedAt = t
        modelContext.insert(session)

        lastCompletedStartedAt = startedAt

        if announcer.isSpeaking { announcer.stopSpeaking(at: .immediate) }
        phase = .idle

        // ✅ 保存後に今日分を再取得（即時反映）
        fetchTodaySessions()
    }

    // MARK: - Stability

    private func stabilityLoop() async {
        lastTick = Date()
        stableSince = nil
        isReady = false

        // ✅ 初回スタック対策：ループ開始前に音声を一度だけ準備
        prepareSpeechIfNeeded()

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

            announceIfNeeded()

            try? await Task.sleep(nanoseconds: tickInterval)
        }
    }

    // 10秒跨ぎだけ読み上げ（レーチャカ/プーラカ別カウント）
    private func announceIfNeeded() {
        guard isReady else { return }

        switch phase {
        case .startToRechaka:
            let seconds = Int(elapsed(from: startedAt))
            guard seconds > 0, seconds % 10 == 0 else { return }
            let bucket = seconds / 10
            guard bucket != lastAnnouncedBucketRechaka else { return }
            lastAnnouncedBucketRechaka = bucket
            speak("\(seconds)秒")

        case .puraakaRunning:
            let seconds = Int(elapsed(from: puraakaAt))
            guard seconds > 0, seconds % 10 == 0 else { return }
            let bucket = seconds / 10
            guard bucket != lastAnnouncedBucketPuraaka else { return }
            lastAnnouncedBucketPuraaka = bucket
            speak("\(seconds)秒")

        default:
            break
        }
    }

    private func prepareSpeechIfNeeded() {
        guard !didPrepareSpeech else { return }
        didPrepareSpeech = true
        prepareSpeechSession()
    }

    // 初回の音声遅延を前倒しで解消する（無音ウォームアップ）
    private func prepareSpeechSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)

            let u = AVSpeechUtterance(string: " ")
            u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
            u.volume = 0.0
            announcer.speak(u)
        } catch {
            // print("prepareSpeechSession error: \(error)")
        }
    }

    private func speak(_ text: String) {
        if announcer.isSpeaking {
            announcer.stopSpeaking(at: .immediate)
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        u.rate = 0.5
        u.pitchMultiplier = 1.0
        u.volume = 1.0
        announcer.speak(u)
    }

    // MARK: - UI / Formatting

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

// MARK: - DateFormatter / 共通フォーマッタ

extension ContentView {
    static let df: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd H:mm:ss"
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
