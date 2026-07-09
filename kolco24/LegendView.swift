//
//  LegendView.swift
//  kolco24
//
//  Вкладка «Легенда» на реальных данных. Порт ПОВЕДЕНИЯ `ui/legend/LegendScreen.kt`: без выбранной
//  команды — онбординг `TeamEmptyState` (легенда привязана к гонке — показывать нечего); иначе список
//  КП выбранной гонки из БД. Данные и derived — из `LegendModel` (наблюдение КП/агрегатов/взятий).
//
//  Locked-КП приходят с `cost == nil` и рендерятся скелетон-строкой (ширины баров детерминированы от
//  `cp.id` — `lockedSkeletonBars`), пока NFC-скан их не раскроет (скан — этап 5). При `lockedCount > 0`
//  сверху — карточка «Скрыто N КП». Прогресс ScoreCard — `takenScore/totalCost` из `legend_meta`
//  (locked-КП скрывают цену, клиент их не суммирует). Фильтр «Все/Не взятые» сохранён.
//

import SwiftUI

// MARK: - Filter
private enum CPFilter: String, CaseIterable {
    case all  = "Все"
    case open = "Не взятые"
}

// MARK: - LegendView
struct LegendView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: LegendModel?
    @State private var filter: CPFilter = .all
    /// Точка входа во флоу выбора (пробрасывается хостом; в превью — no-op).
    var onChooseTeam: () -> Void = {}

    var body: some View {
        content
            .background(Color.paper)
            .navigationTitle("Легенда")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: appModel.selectedTeamId) {
                if model == nil { model = appModel.makeLegendModel() }
                model?.rebind(teamId: appModel.selectedTeamId, raceId: appModel.selectedRaceId)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.selectedTeamState {
        case .loading:
            // Подавляем мигание empty-состояния до первой эмиссии observation.
            Color.paper
        case .none:
            TeamEmptyState(onChooseTeam: onChooseTeam)
        case .missing:
            TeamEmptyState(missing: true, onChooseTeam: onChooseTeam)
        case .present:
            legendList
        }
    }

    @ViewBuilder
    private var legendList: some View {
        let model = model
        let visible = model?.visibleCheckpoints(showOnlyOpen: filter == .open) ?? []
        let takenIds = model?.takenIds ?? []

        List {
            Section {
                if let model, model.lockedCount > 0 {
                    LockedHeroView(lockedCount: model.lockedCount)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                        .listRowSeparator(.hidden)
                }

                ScoreStripView(
                    takenScore: model?.takenScore ?? 0,
                    totalScore: model?.totalScore ?? 0,
                    takenScoring: model?.takenScoring ?? 0,
                    scoringCount: model?.scoringCount ?? 0
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)

                CPFilterPicker(
                    filter: $filter,
                    totalCount: model?.totalCount ?? 0,
                    openCount: (model?.totalCount ?? 0) - (model?.takenCount ?? 0)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(visible, id: \.id) { cp in
                    if cp.locked {
                        LockedRowView(cp: cp)
                            .listRowBackground(Color.card)
                    } else {
                        LegendRowView(cp: cp, taken: takenIds.contains(cp.id))
                            .listRowBackground(Color.card)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(8)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .refreshable {
            if let raceId = appModel.selectedRaceId {
                await appModel.refreshLegend(raceId: raceId)
            }
        }
    }
}

// MARK: - Locked Hero («Скрыто N КП»)
private struct LockedHeroView: View {
    let lockedCount: Int

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.white.opacity(0.07))
                Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                Image(systemName: "lock.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text("Скрыто \(lockedCount) КП")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("Стоимость и описания КП появятся позже")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.68))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DarkHeroBackground() }
        .clipShape(RoundedRectangle(cornerRadius: DS.heroRadius))
        .padding(.horizontal, DS.hPad)
    }
}

// MARK: - Score Strip
private struct ScoreStripView: View {
    let takenScore: Int
    let totalScore: Int
    let takenScoring: Int
    let scoringCount: Int

    private var progress: Double {
        totalScore > 0 ? Double(takenScore) / Double(totalScore) : 0
    }

    private var kpLabel: String {
        // Скрываем «/0» до того, как сервер пришлёт `scoring_count` (порт `totalCount > 0`-гейта).
        scoringCount > 0 ? "\(takenScoring)/\(scoringCount) КП" : "\(takenScoring) КП"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(takenScore)")
                        .font(.mono(20, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text("/ \(totalScore) \(pluralRu(count: totalScore, one: "балл", few: "балла", many: "баллов"))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.sub)
                }
                Spacer()
                Text(kpLabel)
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

// MARK: - Legend Row (open CP)
private struct LegendRowView: View {
    let cp: Checkpoint
    let taken: Bool

    private var display: String {
        let num = String(format: "%02d", cp.number)
        let cost = cp.cost ?? 0
        return cost == 0 ? num : "\(cost)-\(num)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(display)
                .font(.mono(14, weight: .bold))
                .foregroundStyle(taken ? Color.sub.opacity(0.65) : Color.ink)
                .strikethrough(taken, color: Color.sub.opacity(0.35))
                .tracking(0.3)
                .frame(width: 52, alignment: .leading)

            Text(cp.description ?? "")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(taken ? Color.sub : Color.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if taken {
                GreenCheckCircle(size: 22)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Locked Row (masked skeleton)
private struct LockedRowView: View {
    let cp: Checkpoint

    var body: some View {
        let bars = lockedSkeletonBars(checkpointId: cp.id)
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.ink.opacity(0.08))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.sub)
                }
                .frame(width: 18, height: 18)

                Text(String(format: "%02d", cp.number))
                    .font(.mono(14, weight: .bold))
                    .foregroundStyle(Color.sub)
                    .tracking(0.3)
            }
            .frame(width: 52, alignment: .leading)

            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.ink.opacity(0.10))
                        .frame(width: geo.size.width * CGFloat(bars.firstBarFraction), height: 9)
                    if bars.hasSecondBar {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.ink.opacity(0.10))
                            .frame(width: geo.size.width * CGFloat(bars.secondBarFraction), height: 9)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 25)

            Color.clear.frame(width: 22, height: 22)
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
