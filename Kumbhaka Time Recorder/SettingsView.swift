// SettingsView.swift
import SwiftUI
import SwiftData

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

struct SettingsView: View {
    // 計測方式
    @AppStorage("rechakaStartMode") private var rechakaStartModeRaw: String = RechakaStartMode.auto.rawValue

    // 表示形式（TimeDisplayStyle は ContentView.swift 等に既に定義済み）
    @AppStorage("timeDisplayStyle") private var timeDisplayStyleRaw: String = TimeDisplayStyle.minuteSecond.rawValue

    // 目標（秒）と強調色（GoalHighlightColor も既に定義済み）
    @AppStorage("goalSeconds") private var goalSeconds: Double = 0.0
    @AppStorage("goalManualSeconds") private var goalManualSeconds: Double = 0.0
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
                    .onChange(of: goalAutoEnabled) { oldValue, newValue in
                        handleGoalModeChange(from: oldValue, to: newValue)
                    }

                HStack {
                    Text("目標（秒）")
                    Spacer()
                    TextField("0", value: $goalSeconds, formatter: goalFormatter)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .disabled(goalAutoEnabled)
                        .onChange(of: goalSeconds) { _, _ in
                            updateManualGoalIfNeeded()
                        }
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
            if goalAutoEnabled {
                refreshAutoGoalIfNeeded()
            } else {
                goalSeconds = goalManualSeconds
            }
        }
        .onChange(of: sessions) { _, _ in
            refreshAutoGoalIfNeeded()
        }
    }

    private func handleGoalModeChange(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }
        if newValue {
            goalManualSeconds = goalSeconds
            refreshAutoGoalIfNeeded()
        } else {
            goalSeconds = goalManualSeconds
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
}
