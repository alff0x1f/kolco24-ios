import SwiftUI

// MARK: - Model
struct LegendCP: Identifiable {
    let id = UUID()
    let number: String
    let cost: Int
    let name: String
    var taken: Bool

    var display: String { "\(cost)-\(number)" }
}

// MARK: - Mock data
private let mockCPs: [LegendCP] = [
    .init(number: "00", cost: 0, name: "Тест", taken: true),
    .init(number: "01", cost: 5, name: "Дерево в 20м на северо-восток от геоглифа", taken: false),
    .init(number: "02", cost: 2, name: "Отдельно стоящая сухая берёза", taken: true),
    .init(number: "03", cost: 4, name: "Дерево в лощине под скалами", taken: false),
    .init(number: "04", cost: 3, name: "Дерево в лесополосе", taken: true),
    .init(number: "05", cost: 2, name: "Дерево на слиянии двух рек", taken: false),
    .init(number: "06", cost: 3, name: "Отдельно стоящая берёза", taken: false),
    .init(number: "07", cost: 4, name: "Триангулятор на вершине", taken: true),
    .init(number: "08", cost: 4, name: "Четырёхствольная берёза в 20м от подножия скал", taken: false),
    .init(number: "09", cost: 4, name: "Горизонтальное дерево в 40м от подножия", taken: false),
    .init(number: "10", cost: 5, name: "Скальный останец на хребте", taken: false),
    .init(number: "11", cost: 5, name: "Слияние ручья и реки", taken: false),
]

// MARK: - Filter
private enum CPFilter: String, CaseIterable {
    case all  = "Все"
    case open = "Не взятые"
}

// MARK: - LegendView
struct LegendView: View {
    @State private var filter: CPFilter = .all

    private var takenCount:  Int { mockCPs.filter(\.taken).count }
    private var takenScore:  Int { mockCPs.filter(\.taken).reduce(0) { $0 + $1.cost } }
    private var totalScore:  Int { mockCPs.reduce(0) { $0 + $1.cost } }

    private var visible: [LegendCP] {
        let sorted = mockCPs.sorted { $0.number < $1.number }
        return filter == .open ? sorted.filter { !$0.taken } : sorted
    }

    var body: some View {
        List {
            // Score strip + filter (transparent background rows)
            Section {
                ScoreStripView(
                    taken: takenCount, total: mockCPs.count,
                    takenScore: takenScore, totalScore: totalScore
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)

                CPFilterPicker(
                    filter: $filter,
                    totalCount: mockCPs.count,
                    openCount: mockCPs.count - takenCount
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            // CP rows
            Section {
                ForEach(visible) { cp in
                    LegendRowView(cp: cp)
                        .listRowBackground(Color.card)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(8)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .navigationTitle("Легенда")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Score Strip
private struct ScoreStripView: View {
    let taken: Int
    let total: Int
    let takenScore: Int
    let totalScore: Int

    private var progress: Double {
        totalScore > 0 ? Double(takenScore) / Double(totalScore) : 0
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(takenScore)")
                        .font(.mono(20, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text("/ \(totalScore) баллов")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.sub)
                }
                Spacer()
                Text("\(taken)/\(total) КП")
                    .font(.mono(12, weight: .semibold))
                    .foregroundStyle(Color.sub)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.sub.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color.good, Color.goodEnd],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }
}

// MARK: - Legend Row
private struct LegendRowView: View {
    let cp: LegendCP

    var body: some View {
        HStack(spacing: 12) {
            Text(cp.display)
                .font(.mono(14, weight: .bold))
                .foregroundStyle(cp.taken ? Color.sub.opacity(0.65) : Color.ink)
                .strikethrough(cp.taken, color: Color.sub.opacity(0.35))
                .tracking(0.3)
                .frame(width: 52, alignment: .leading)

            Text(cp.name)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(cp.taken ? Color.sub : Color.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if cp.taken {
                GreenCheckCircle(size: 22)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - CPFilterPicker
private struct CPFilterPicker: View {
    @Binding var filter: CPFilter
    let totalCount: Int
    let openCount: Int

    var body: some View {
        HStack(spacing: 0) {
            filterButton(.all,  count: totalCount)
            filterButton(.open, count: openCount)
        }
        .padding(2)
        .background(Color.sub.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func filterButton(_ option: CPFilter, count: Int) -> some View {
        Button {
            filter = option
        } label: {
            HStack(spacing: 6) {
                Text(option.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("\(count)")
                    .font(.mono(11, weight: .bold))
                    .foregroundStyle(filter == option ? Color.sub : Color.sub.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(filter == option ? Color.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .shadow(
                color: filter == option ? Color.cardShadow : Color.clear,
                radius: 4, x: 0, y: 1.5
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview("Light") {
    NavigationStack { LegendView() }
}

#Preview("Dark") {
    NavigationStack { LegendView() }
        .preferredColorScheme(.dark)
}
