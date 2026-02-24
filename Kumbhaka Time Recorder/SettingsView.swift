import SwiftUI
import SwiftData
import AVFoundation

// ★RechakaStartMode だけここに置く（見つからない問題の対策）
enum RechakaStartMode: String, CaseIterable, Identifiable {
    case auto
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自動"
        case .manual: return "手動"
        }
    }
}

enum AutoAdvanceMode: String, CaseIterable, Identifiable {
    case button
    case sound

    var id: String { rawValue }

    var label: String {
        switch self {
        case .button: return "ボタン"
        case .sound: return "音検知"
        }
    }
}

enum SoundStartMode: String, CaseIterable, Identifiable {
    case button
    case sound

    var id: String { rawValue }

    var label: String {
        switch self {
        case .button: return "ボタン開始"
        case .sound: return "音で開始"
        }
    }
}

enum MicInputPriority: String, CaseIterable, Identifiable {
    case auto
    case builtIn
    case bluetooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自動"
        case .builtIn: return "本体優先"
        case .bluetooth: return "Bluetooth優先"
        }
    }
}

struct SettingsView: View {
    private enum PromptTarget {
        case rechakaStart
        case rechakaStop
        case puraakaStop
    }

    // 計測方式
    @AppStorage("rechakaStartMode") private var rechakaStartModeRaw: String = RechakaStartMode.auto.rawValue
    @AppStorage("autoAdvanceMode") private var autoAdvanceModeRaw: String = AutoAdvanceMode.button.rawValue
    @AppStorage("soundStartMode") private var soundStartModeRaw: String = SoundStartMode.button.rawValue
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
    @State private var pronunciationPreviewText: String = "レーチャカ"
    @State private var editingPromptTarget: PromptTarget? = nil
    @State private var promptDraft: String = ""
    @State private var showPromptEditor: Bool = false

    // 表示形式（TimeDisplayStyle は ContentView.swift 等に既に定義済み）
    @AppStorage("timeDisplayStyle") private var timeDisplayStyleRaw: String = TimeDisplayStyle.minuteSecond.rawValue

    // 目標（秒）と強調色（GoalHighlightColor も既に定義済み）
    @AppStorage("goalSeconds") private var goalSeconds: Double = 0.0
    @AppStorage("goalAutoEnabled") private var goalAutoEnabled: Bool = true
    @AppStorage("goalHighlightColor") private var goalColorRaw: String = GoalHighlightColor.red.rawValue

    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]

    private let goalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    var body: some View {
        Form {
            Section("計測方式") {
                Picker("方式", selection: $rechakaStartModeRaw) {
                    ForEach(RechakaStartMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue) // Stringで統一
                    }
                }
                .pickerStyle(.segmented)

                Picker("進行方法", selection: $autoAdvanceModeRaw) {
                    ForEach(AutoAdvanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if autoAdvanceModeRaw == AutoAdvanceMode.sound.rawValue {
                    Picker("開始方法", selection: $soundStartModeRaw) {
                        ForEach(SoundStartMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }

                    Picker("入力優先", selection: $micInputPriorityRaw) {
                        ForEach(MicInputPriority.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }

                    Toggle("マイク自動キャリブレーション", isOn: $soundAutoCalibrationEnabled)

                    HStack {
                        Text("検知しきい値")
                        Spacer()
                        Text(String(format: "%.2f", soundDetectionThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $soundDetectionThreshold, in: 0.02...0.30, step: 0.01)

                    if rechakaStartModeRaw == RechakaStartMode.auto.rawValue {
                        Text("値を小さくすると小さい音でも反応し、値を大きくすると大きい音で反応します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("自動キャリブレーションON時は、開始直後に周囲ノイズを測ってしきい値を自動補正します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("スタート後は、音を検知するたびに レーチャカ開始 → プーラカ開始 → 記録終了 と進みます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("値を小さくすると小さい音でも反応し、値を大きくすると大きい音で反応します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("自動キャリブレーションON時は、開始直後に周囲ノイズを測ってしきい値を自動補正します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("手動モードでは、レーチャカスタート後は音を検知するたびに レーチャカ開始 → レーチャカ停止 → プーラカ開始 → 記録終了 と進みます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("読み上げ調整") {
                editableSpeechToggle(target: .rechakaStart, isOn: $speechEnableRechakaStart)
                editableSpeechToggle(target: .rechakaStop, isOn: $speechEnableRechakaStop)
                if rechakaStartModeRaw == RechakaStartMode.manual.rawValue {
                    Toggle("プーラカスタート", isOn: $speechEnablePuraakaStart)
                }
                editableSpeechToggle(target: .puraakaStop, isOn: $speechEnablePuraakaStop)
                Toggle("結果読み上げ", isOn: $speechEnableResultSummary)
                Toggle("10秒ごとの読み上げ", isOn: $speechEnableElapsedAnnouncement)

                HStack {
                    Text("話す速さ")
                    Spacer()
                    Text(String(format: "%.2f", speechRate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speechRate, in: 0.30...0.65, step: 0.01)

                HStack {
                    Text("声の高さ")
                    Spacer()
                    Text(String(format: "%.2f", speechPitch))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speechPitch, in: 0.70...1.40, step: 0.01)

                HStack {
                    Text("読み上げ音量")
                    Spacer()
                    Text(String(format: "%.2f", speechVolume))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speechVolume, in: 0.0...1.0, step: 0.05)

                Text("読み分け辞書（1行ごとに 単語=読み）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $speechPronunciationMap)
                    .frame(minHeight: 100)

                HStack(spacing: 10) {
                    TextField("試し読みする単語", text: $pronunciationPreviewText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        previewPronunciation()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("発音を再生")
                }

                Text("例: レーチャカ=レーチャカ, プーラカ=プーラカ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("表示形式") {
                Picker("時間の表示", selection: $timeDisplayStyleRaw) {
                    ForEach(TimeDisplayStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue) // Stringで統一
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("目標") {
                Toggle("自動で設定", isOn: $goalAutoEnabled)
                    .onChange(of: goalAutoEnabled) { _, _ in
                        refreshAutoGoalIfNeeded()
                    }

                HStack {
                    Text("目標（秒）")
                    Spacer()
                    TextField("0", value: $goalSeconds, formatter: goalFormatter)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .disabled(goalAutoEnabled)
                }

                Picker("達成時の色", selection: $goalColorRaw) {
                    ForEach(GoalHighlightColor.allCases) { c in
                        Text(c.label).tag(c.rawValue) // Stringで統一
                    }
                }
            }

            Section {
                Text("※ 目標（秒）が 0 の場合は、色の強調は無効になります。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("設定")
        .onAppear {
            refreshAutoGoalIfNeeded()
        }
        .onChange(of: sessions) { _, _ in
            refreshAutoGoalIfNeeded()
        }
        .alert("読み上げ文言を編集", isPresented: $showPromptEditor) {
            TextField("文言", text: $promptDraft)
            Button("保存") {
                savePromptDraft()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if let target = editingPromptTarget {
                Text(promptEditorMessage(for: target))
            } else {
                Text("読み上げ文言を入力してください。")
            }
        }
    }

    private func refreshAutoGoalIfNeeded() {
        guard goalAutoEnabled else { return }
        let newGoal = calculateAutoGoalSeconds()
        if abs(goalSeconds - newGoal) > 0.01 {
            goalSeconds = newGoal
        }
    }

    private func calculateAutoGoalSeconds() -> Double {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let puraakaTimes = sessions.compactMap { session -> Double? in
            guard session.startedAt >= weekAgo else { return nil }
            return session.record2Seconds
        }
        let sortedTimes = puraakaTimes.sorted(by: >)
        let topTimes = sortedTimes.prefix(10)
        guard !topTimes.isEmpty else { return 0.0 }
        let total = topTimes.reduce(0.0, +)
        return total / Double(topTimes.count)
    }

    private func previewPronunciation() {
        let source = pronunciationPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }

        let converted = applyPronunciationOverrides(to: source)
        let utterance = AVSpeechUtterance(string: converted)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = Float(min(0.65, max(0.30, speechRate)))
        utterance.pitchMultiplier = Float(min(1.40, max(0.70, speechPitch)))
        utterance.volume = Float(min(1.0, max(0.0, speechVolume)))
        SpeechPreviewPlayer.shared.play(utterance)
    }

    private func editableSpeechToggle(target: PromptTarget, isOn: Binding<Bool>) -> some View {
        HStack {
            Button {
                editingPromptTarget = target
                promptDraft = promptValue(for: target)
                showPromptEditor = true
            } label: {
                HStack(spacing: 6) {
                    Text(promptLabel(for: target))
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func promptValue(for target: PromptTarget) -> String {
        switch target {
        case .rechakaStart:
            return autoVoicePromptRechakaStart
        case .rechakaStop:
            return autoVoicePromptRechakaStop
        case .puraakaStop:
            return autoVoicePromptPuraakaStop
        }
    }

    private func promptLabel(for target: PromptTarget) -> String {
        if rechakaStartModeRaw == RechakaStartMode.manual.rawValue, target == .rechakaStop {
            return "レーチャカストップ"
        }
        let value = promptValue(for: target).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return promptDefault(for: target)
        }
        return value
    }

    private func promptDefault(for target: PromptTarget) -> String {
        switch target {
        case .rechakaStart:
            return "レーチャカスタート"
        case .rechakaStop:
            return "レーチャカストップ"
        case .puraakaStop:
            return "プーラカストップ"
        }
    }

    private func promptEditorMessage(for target: PromptTarget) -> String {
        switch target {
        case .rechakaStart:
            return "レーチャカ開始時に読み上げる文言を編集します。"
        case .rechakaStop:
            return "レーチャカ停止時に読み上げる文言を編集します。"
        case .puraakaStop:
            return "プーラカ停止時に読み上げる文言を編集します。"
        }
    }

    private func savePromptDraft() {
        guard let target = editingPromptTarget else { return }
        switch target {
        case .rechakaStart:
            autoVoicePromptRechakaStart = promptDraft
        case .rechakaStop:
            autoVoicePromptRechakaStop = promptDraft
        case .puraakaStop:
            autoVoicePromptPuraakaStop = promptDraft
        }
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
}

private final class SpeechPreviewPlayer {
    static let shared = SpeechPreviewPlayer()
    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    func play(_ utterance: AVSpeechUtterance) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
    }
}
