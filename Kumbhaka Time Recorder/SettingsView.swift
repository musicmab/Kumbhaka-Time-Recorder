import SwiftUI

enum RechakaStartMode: String, CaseIterable, Identifiable {
    case auto = "auto"       // プーラカ押下で即レーチャカ開始
    case manual = "manual"   // プーラカ後にスタートを押してレーチャカ開始

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自動（プーラカで開始）"
        case .manual: return "手動（再スタートで開始）"
        }
    }
}

struct SettingsView: View {
    @AppStorage("rechakaStartMode") private var rechakaStartModeRaw: String = RechakaStartMode.auto.rawValue

    var body: some View {
        Form {
            Section("レーチャカの開始") {
                Picker("開始方式", selection: $rechakaStartModeRaw) {
                    ForEach(RechakaStartMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }

            Section {
                Text("自動：プーラカを押した瞬間からレーチャカの秒数を計測します。")
                Text("手動：プーラカ後はいったん停止し、レーチャカスタートを押した瞬間からレーチャカを計測します。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("設定")
    }
}
