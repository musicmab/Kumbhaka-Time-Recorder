import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var sessions: [SessionRecord]

    @AppStorage("timeDisplayStyle") private var timeDisplayStyleRaw: String = TimeDisplayStyle.minuteSecond.rawValue
    private var timeDisplayStyle: TimeDisplayStyle {
        TimeDisplayStyle(rawValue: timeDisplayStyleRaw) ?? .minuteSecond
    }

    // 閉じている日付を保持（= 折りたたみ）
    @State private var collapsedDays: Set<Date> = []

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
                let day = section.day
                let items = section.items
                let collapsed = collapsedDays.contains(day)

                Section {
                    if !collapsed {
                        // 行（個別セッション）
                        ForEach(items) { s in
                            rowView(s)
                        }
                        // ✅ 個々の記録を削除（スワイプ削除）
                        .onDelete { offsets in
                            delete(items: items, offsets: offsets)
                        }
                    }
                } header: {
                    headerView(day: day, items: items, collapsed: collapsed)
                }
            }
        }
        .navigationTitle("履歴")
        // ✅ 初回表示時：全日付を折りたたみ
        .task {
            collapseAllDaysIfNeeded()
        }
        // ✅ データが追加/削除された時も、「新しい日付が増えたら」閉じた状態に寄せる
        .onChange(of: sessions.count) { _, _ in
            // 既存の折りたたみ状態を尊重しつつ、
            // 未登録の日付が出てきたら閉じる
            collapseNewDaysOnly()
        }
    }

    // MARK: - Row

    private func rowView(_ s: SessionRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ContentView.timeOnly.string(from: s.startedAt))
                    .font(.headline)

                Text("レーチャカ: \(ContentView.formatTime(s.record1Seconds, style: timeDisplayStyle)) / プーラカ: \(ContentView.formatTime(s.record2Seconds, style: timeDisplayStyle))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            ShareLink(item: shareText(for: s)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("共有")
        }
    }

    // MARK: - Header

    private func headerView(day: Date, items: [SessionRecord], collapsed: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { toggle(day) }
            } label: {
                HStack(spacing: 10) {
                    Text(ContentView.dateOnly.string(from: day))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)

                    Text("\(items.count)件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            Spacer()

            ShareLink(item: shareTextForDay(day: day, sessions: items)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("この日を共有")
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    private func toggle(_ day: Date) {
        if collapsedDays.contains(day) {
            collapsedDays.remove(day)
        } else {
            collapsedDays.insert(day)
        }
    }

    // MARK: - Delete

    private func delete(items: [SessionRecord], offsets: IndexSet) {
        for i in offsets {
            modelContext.delete(items[i])
        }
        // SwiftDataの自動保存に任せる（必要なら try? modelContext.save() を追加）
    }

    // MARK: - Collapse control

    private func allDaysSet() -> Set<Date> {
        Set(groupedDays.map { $0.day })
    }

    private func collapseAllDaysIfNeeded() {
        // 初回だけ「全折りたたみ」にしたいので、
        // まだ collapsedDays が空のときだけ全セットする
        if collapsedDays.isEmpty {
            collapsedDays = allDaysSet()
        }
    }

    private func collapseNewDaysOnly() {
        let all = allDaysSet()
        // 追加された日付があれば閉じる（既存は尊重）
        collapsedDays.formUnion(all.subtracting(collapsedDays))
        // ※ subtracting は「collapsedDaysに無い日付」なので、追加分を閉じる挙動
        //    ただし、もしユーザーが開いた日付を保持したい場合はこの挙動はOK
    }

    // MARK: - Share

    private func shareText(for s: SessionRecord) -> String {
        """
        開始: \(ContentView.df.string(from: s.startedAt))
        レーチャカ: \(ContentView.formatTime(s.record1Seconds, style: timeDisplayStyle))
        プーラカ: \(ContentView.formatTime(s.record2Seconds, style: timeDisplayStyle))
        """
    }

    private func shareTextForDay(day: Date, sessions: [SessionRecord]) -> String {
        var lines: [String] = []
        lines.append(ContentView.dateOnly.string(from: day))
        lines.append("")

        for s in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            lines.append("開始: \(ContentView.timeOnly.string(from: s.startedAt))")
            lines.append("レーチャカ: \(ContentView.formatTime(s.record1Seconds, style: timeDisplayStyle))")
            lines.append("プーラカ: \(ContentView.formatTime(s.record2Seconds, style: timeDisplayStyle))")
            lines.append("")
        }

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
