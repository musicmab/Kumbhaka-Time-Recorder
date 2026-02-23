// ContentView.swift
import SwiftUI
import SwiftData
import AudioToolbox
import AVFoundation

private final class SoundDetector {
    enum DetectorError: Error {
        case invalidInputFormat
    }

    private let engine = AVAudioEngine()
    private var onDetect: (() -> Void)?
    private var threshold: Float = 0.10
    private var effectiveThreshold: Float = 0.10
    private var cooldown: TimeInterval = 0.55
    private var inputPriority: MicInputPriority = .auto
    private var autoCalibrationEnabled: Bool = true
    private var calibrationEndsAt: Date?
    private var calibrationRmsTotal: Float = 0
    private var calibrationSampleCount: Int = 0
    private var calibrationPeakRms: Float = 0
    private var lastDetectedAt: Date = .distantPast
    private var wasLoud: Bool = false
    private var routeChangeObserver: NSObjectProtocol?

    func start(
        threshold: Float = 0.10,
        cooldown: TimeInterval = 0.55,
        inputPriority: MicInputPriority = .auto,
        autoCalibrationEnabled: Bool = true,
        onDetect: @escaping () -> Void
    ) throws {
        stop()

        self.threshold = threshold
        self.effectiveThreshold = threshold
        self.cooldown = cooldown
        self.inputPriority = inputPriority
        self.autoCalibrationEnabled = autoCalibrationEnabled
        self.onDetect = onDetect
        resetCalibrationState()
        if autoCalibrationEnabled {
            calibrationEndsAt = Date().addingTimeInterval(1.0)
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        try configureAudioSessionForCurrentRoute(session)
        observeRouteChanges()

        try reinstallTapAndRestartEngine()
    }

    func stop() {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onDetect = nil
        wasLoud = false
    }

    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
    }

    private func handleRouteChange() {
        guard onDetect != nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            try configureAudioSessionForCurrentRoute(session)
            try reinstallTapAndRestartEngine()
            wasLoud = false
            lastDetectedAt = Date()
            resetCalibrationState()
            if autoCalibrationEnabled {
                calibrationEndsAt = Date().addingTimeInterval(0.8)
            }
        } catch {
            // 入力切替直後に一時失敗することがあるため、ここでは無視する。
        }
    }

    private func reinstallTapAndRestartEngine() throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
        let format = isValid(format: inputFormat) ? inputFormat : outputFormat
        guard isValid(format: format) else {
            throw DetectorError.invalidInputFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analyze(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func analyze(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sum: Float = 0
        for i in stride(from: 0, to: frameCount, by: 2) {
            let sample = channelData[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(max(1, frameCount / 2)))
        processCalibrationIfNeeded(rms: rms)

        let now = Date()

        if rms >= effectiveThreshold {
            if !wasLoud && now.timeIntervalSince(lastDetectedAt) >= cooldown {
                lastDetectedAt = now
                DispatchQueue.main.async { [onDetect] in
                    onDetect?()
                }
            }
            wasLoud = true
        } else if rms <= (effectiveThreshold * 0.5) {
            wasLoud = false
        }
    }

    private func processCalibrationIfNeeded(rms: Float) {
        guard let calibrationEndsAt else { return }
        if Date() < calibrationEndsAt {
            calibrationRmsTotal += rms
            calibrationSampleCount += 1
            calibrationPeakRms = max(calibrationPeakRms, rms)
            return
        }

        let average = calibrationRmsTotal / Float(max(1, calibrationSampleCount))
        let candidate = max(threshold, average * 3.0, calibrationPeakRms * 0.65)
        effectiveThreshold = min(0.40, max(0.02, candidate))
        self.calibrationEndsAt = nil
    }

    private func resetCalibrationState() {
        effectiveThreshold = threshold
        calibrationRmsTotal = 0
        calibrationSampleCount = 0
        calibrationPeakRms = 0
        calibrationEndsAt = nil
    }

    private func isValid(format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func configureAudioSessionForCurrentRoute(_ session: AVAudioSession) throws {
        let inputs = session.availableInputs ?? []
        let builtInMic = inputs.first(where: { $0.portType == .builtInMic })
        let bluetoothMic = inputs.first(where: { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE })
        let currentRoute = session.currentRoute
        let isBluetoothRouteActive =
            currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }) ||
            currentRoute.outputs.contains(where: { $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE })

        switch inputPriority {
        case .auto:
            if isBluetoothRouteActive, let bluetoothMic {
                try session.setPreferredInput(bluetoothMic)
                try session.setMode(.voiceChat)
                return
            }
            if let builtInMic {
                try session.setPreferredInput(builtInMic)
                try session.setMode(.measurement)
                try session.overrideOutputAudioPort(.speaker)
                return
            }
            if let bluetoothMic {
                try session.setPreferredInput(bluetoothMic)
                try session.setMode(.voiceChat)
                return
            }

        case .builtIn:
            if let builtInMic {
                try session.setPreferredInput(builtInMic)
                try session.setMode(.measurement)
                try session.overrideOutputAudioPort(.speaker)
                return
            }
            if let bluetoothMic {
                try session.setPreferredInput(bluetoothMic)
                try session.setMode(.voiceChat)
                return
            }

        case .bluetooth:
            if let bluetoothMic {
                try session.setPreferredInput(bluetoothMic)
                try session.setMode(.voiceChat)
                return
            }
            if let builtInMic {
                try session.setPreferredInput(builtInMic)
                try session.setMode(.measurement)
                try session.overrideOutputAudioPort(.speaker)
                return
            }
        }

        try session.setPreferredInput(nil)
        try session.setMode(.measurement)
        try session.overrideOutputAudioPort(.speaker)
    }
}

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

    // ✅ 今日分の履歴（自前 fetch）
    @State private var todaySessions: [SessionRecord] = []

    // 設定（永続）
    @AppStorage("rechakaStartMode") private var rechakaStartModeRaw: String = RechakaStartMode.auto.rawValue
    private var rechakaStartMode: RechakaStartMode {
        RechakaStartMode(rawValue: rechakaStartModeRaw) ?? .auto
    }
    @AppStorage("autoAdvanceMode") private var autoAdvanceModeRaw: String = AutoAdvanceMode.button.rawValue
    private var autoAdvanceMode: AutoAdvanceMode {
        AutoAdvanceMode(rawValue: autoAdvanceModeRaw) ?? .button
    }
    @AppStorage("soundDetectionThreshold") private var soundDetectionThreshold: Double = 0.09
    @AppStorage("micInputPriority") private var micInputPriorityRaw: String = MicInputPriority.auto.rawValue
    @AppStorage("soundAutoCalibrationEnabled") private var soundAutoCalibrationEnabled: Bool = true
    @AppStorage("autoVoicePromptRechakaStart") private var autoVoicePromptRechakaStart: String = "レーチャカスタート"
    @AppStorage("autoVoicePromptRechakaStop") private var autoVoicePromptRechakaStop: String = "レーチャカストップ"
    @AppStorage("autoVoicePromptPuraakaStop") private var autoVoicePromptPuraakaStop: String = "プーラカストップ"
    @AppStorage("speechRate") private var speechRate: Double = 0.5
    @AppStorage("speechPitch") private var speechPitch: Double = 1.0
    @AppStorage("speechVolume") private var speechVolume: Double = 1.0
    @AppStorage("speechPronunciationMap") private var speechPronunciationMap: String = ""
    @AppStorage("speechEnableRechakaStart") private var speechEnableRechakaStart: Bool = true
    @AppStorage("speechEnableRechakaStop") private var speechEnableRechakaStop: Bool = true
    @AppStorage("speechEnablePuraakaStart") private var speechEnablePuraakaStart: Bool = true
    @AppStorage("speechEnablePuraakaStop") private var speechEnablePuraakaStop: Bool = true
    @AppStorage("speechEnableResultSummary") private var speechEnableResultSummary: Bool = true
    @AppStorage("speechEnableElapsedAnnouncement") private var speechEnableElapsedAnnouncement: Bool = true
    private var usesSoundAdvance: Bool {
        autoAdvanceMode == .sound
    }
    private var micInputPriority: MicInputPriority {
        MicInputPriority(rawValue: micInputPriorityRaw) ?? .auto
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

    // 今日の記録：削除確認
    @State private var sessionPendingDelete: SessionRecord? = nil
    @State private var showDeleteAlert: Bool = false

    // 準備中 点滅
    @State private var isPreparingBlink = false

    // ===== 安定するまで false =====
    @State private var isReady = false
    @State private var lastTick: Date = Date()
    @State private var stableSince: Date? = nil

    private let tickInterval: UInt64 = 100_000_000 // 0.1s
    private let hangThreshold: TimeInterval = 0.25
    private let requiredStable: TimeInterval = 2.0

    // ===== 音検知 =====
    @State private var soundDetector: SoundDetector = SoundDetector()
    @State private var soundDetectorRunning = false
    @State private var micPermissionAsked = false
    @State private var micPermissionGranted = false
    @State private var showMicPermissionAlert = false

    // ===== フェーズ =====
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

    // ===== 結果（表示は レーチャカ→プーラカ）=====
    @State private var lastRechaka: Double?
    @State private var lastPuraaka: Double?

    @State private var now: Date = Date()

    // ===== 10秒ごとのアナウンス =====
    @State private var lastAnnouncedBucketRechaka: Int = -1
    @State private var lastAnnouncedBucketPuraaka: Int = -1
    @State private var ignoreDetectedUntil: Date = .distantPast

    // ✅ 音声初期化は一度だけ
    @State private var didPrepareSpeech: Bool = false
    private let announcer = AVSpeechSynthesizer()

    // ✅ 日付跨ぎ監視タスク
    @State private var midnightTask: Task<Void, Never>? = nil

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

    private var soundModeGuideText: String? {
        guard usesSoundAdvance else { return nil }

        switch rechakaStartMode {
        case .auto:
            switch phase {
            case .idle:
                return "スタートでレーチャカ開始（音検知は起動時から有効）"
            case .startToRechaka:
                return "次の音でプーラカ開始（レーチャカ停止）"
            case .puraakaRunning:
                return "次の音でストップして記録保存"
            default:
                return nil
            }
        case .manual:
            switch phase {
            case .idle:
                return "レーチャカスタートで計測開始（音検知は起動時から有効）"
            case .startToRechaka:
                return "次の音でレーチャカ停止"
            case .waitPuraakaStart:
                return "次の音でプーラカ開始"
            case .puraakaRunning:
                return "次の音でストップして記録保存"
            default:
                return nil
            }
        }
    }

    // MARK: - メイン共有

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

                // ✅ 秒表示は画面中央固定／共有は右端
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

                    if let guide = soundModeGuideText {
                        Text(guide)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                stopSoundDetectionIfNeeded()
            }
            .onChange(of: soundDetectionThreshold) { _, _ in
                if soundDetectorRunning {
                    stopSoundDetectionIfNeeded()
                }
            }
            .onChange(of: micInputPriorityRaw) { _, _ in
                if soundDetectorRunning {
                    stopSoundDetectionIfNeeded()
                }
            }
            .onChange(of: soundAutoCalibrationEnabled) { _, _ in
                if soundDetectorRunning {
                    stopSoundDetectionIfNeeded()
                }
            }
            .alert("マイク許可が必要です", isPresented: $showMicPermissionAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("音検知モードを使うには、マイク許可を有効にし、入力デバイスが利用可能な状態にしてください。")
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

    // MARK: - 今日分履歴パネル（均等ヘッダー + 目標達成回数 + 個別削除）

    private var todayHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ✅ 「今日の記録」「件数」「目標達成回数」を均等配置
            HStack {
                Text("今日の記録")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(todaySessions.count)件")
                    .font(.subheadline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .center)

                if goalSeconds > 0 {
                    Text("目標達成 \(goalAchievedCountToday)回")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    // 目標未設定でも幅を揃える
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
        case .idle, .waitPuraakaStart:
            return "0.0 秒"
        case .startToRechaka:
            return "\(truncate1(elapsed(from: startedAt))) 秒"
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
        if !speechEnableRechakaStart {
            if announcer.isSpeaking { announcer.stopSpeaking(at: .immediate) }
        } else if rechakaStartMode == .auto {
            speak(normalizedPrompt(autoVoicePromptRechakaStart, fallback: "レーチャカスタート"), suppressDetection: true)
        } else {
            speak("レーチャカスタート", suppressDetection: true)
        }
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
            phase = .puraakaRunning
            if speechEnableRechakaStop {
                speak(normalizedPrompt(autoVoicePromptRechakaStop, fallback: "レーチャカストップ"), suppressDetection: true)
            } else if announcer.isSpeaking {
                announcer.stopSpeaking(at: .immediate)
            }

        case .manual:
            puraakaAt = nil
            phase = .waitPuraakaStart
            if speechEnableRechakaStop {
                speak("レーチャカストップ", suppressDetection: true)
            } else if announcer.isSpeaking {
                announcer.stopSpeaking(at: .immediate)
            }
        }
    }

    private func startPuraakaPhaseManually() {
        prepareSpeechIfNeeded()

        let t = Date()
        puraakaAt = t
        now = t
        phase = .puraakaRunning

        lastAnnouncedBucketPuraaka = -1
        if speechEnablePuraakaStart {
            speak("プーラカスタート", suppressDetection: true)
        } else if announcer.isSpeaking {
            announcer.stopSpeaking(at: .immediate)
        }
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

        let rechakaText = Self.formatTime(lastRechaka, style: timeDisplayStyle)
        let puraakaText = Self.formatTime(lastPuraaka, style: timeDisplayStyle)
        let resultPrompt = "今回の記録は、レーチャカ \(rechakaText) プーラカ \(puraakaText) でした。"
        var prompts: [String] = []
        if speechEnablePuraakaStop {
            if rechakaStartMode == .auto {
                prompts.append(normalizedPrompt(autoVoicePromptPuraakaStop, fallback: "プーラカストップ"))
            } else {
                prompts.append("プーラカストップ")
            }
        }
        if speechEnableResultSummary {
            prompts.append(resultPrompt)
        }

        if !prompts.isEmpty {
            speak(prompts.joined(separator: "。"), suppressDetection: true)
        } else if announcer.isSpeaking {
            announcer.stopSpeaking(at: .immediate)
        }
        phase = .idle

        // ✅ 保存後に今日分を再取得（即時反映）
        fetchTodaySessions()
    }

    private func handleDetectedSoundAdvance() {
        guard isReady, usesSoundAdvance else { return }
        guard Date() >= ignoreDetectedUntil else { return }

        switch phase {
        case .startToRechaka:
            rechakaStop()
        case .waitPuraakaStart:
            startPuraakaPhaseManually()
        case .puraakaRunning:
            finishPuraakaAndSave()
        default:
            break
        }
    }

    // MARK: - Stability

    private func stabilityLoop() async {
        lastTick = Date()
        stableSince = nil
        isReady = false

        // ✅ 初回の音声遅延対策（ウォームアップ）
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

            refreshSoundDetectionStateIfNeeded()
            announceIfNeeded()
            try? await Task.sleep(nanoseconds: tickInterval)
        }
    }

    // 10秒ごとの読み上げ（レーチャカ/プーラカ別カウント）
    private func announceIfNeeded() {
        guard isReady else { return }
        guard speechEnableElapsedAnnouncement else { return }

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

    private func refreshSoundDetectionStateIfNeeded() {
        guard usesSoundAdvance else {
            stopSoundDetectionIfNeeded()
            return
        }

        guard isReady else { return }

        if soundDetectorRunning { return }

        if micPermissionGranted {
            do {
                try soundDetector.start(
                    threshold: Float(soundDetectionThreshold),
                    cooldown: 0.5,
                    inputPriority: micInputPriority,
                    autoCalibrationEnabled: soundAutoCalibrationEnabled
                ) {
                    handleDetectedSoundAdvance()
                }
                soundDetectorRunning = true
            } catch {
                soundDetectorRunning = false
                showMicPermissionAlert = true
            }
            return
        }

        if !micPermissionAsked {
            micPermissionAsked = true
            let permissionHandler: (Bool) -> Void = { granted in
                DispatchQueue.main.async {
                    micPermissionGranted = granted
                    if !granted {
                        showMicPermissionAlert = true
                    }
                }
            }

            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission(completionHandler: permissionHandler)
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission(permissionHandler)
            }
        }
    }

    private func stopSoundDetectionIfNeeded() {
        guard soundDetectorRunning else { return }
        soundDetector.stop()
        soundDetectorRunning = false
    }

    private func prepareSpeechIfNeeded() {
        guard !didPrepareSpeech else { return }
        didPrepareSpeech = true
        prepareSpeechSession()
    }

    // 初回の音声遅延を前倒しで解消（無音ウォームアップ）
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

    private func speak(_ text: String, suppressDetection: Bool = false) {
        // ボタン状態が変わる案内時のみ、短時間だけ検知を無効化する
        if suppressDetection {
            let suppressionSeconds = (rechakaStartMode == .manual) ? 2.0 : 4.0
            ignoreDetectedUntil = Date().addingTimeInterval(suppressionSeconds)
        }
        if announcer.isSpeaking {
            announcer.stopSpeaking(at: .immediate)
        }
        let convertedText = applyPronunciationOverrides(to: text)
        let u = AVSpeechUtterance(string: convertedText)
        u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        u.rate = Float(min(0.65, max(0.30, speechRate)))
        u.pitchMultiplier = Float(min(1.40, max(0.70, speechPitch)))
        u.volume = Float(min(1.0, max(0.0, speechVolume)))
        announcer.speak(u)
    }

    private func applyPronunciationOverrides(to text: String) -> String {
        let lines = speechPronunciationMap.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return text }

        var converted = text
        for line in lines {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }

            let from: String
            let to: String
            if let r = raw.range(of: "=") {
                from = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                to = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = raw.range(of: "：") {
                from = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                to = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = raw.range(of: "->") {
                from = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                to = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }

            guard !from.isEmpty, !to.isEmpty else { continue }
            converted = converted.replacingOccurrences(of: from, with: to)
        }
        return converted
    }

    private func normalizedPrompt(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
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

// MARK: - DateFormatter / 共通フォーマッタ（HistoryView が参照する dateOnly を必ず含める）

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
