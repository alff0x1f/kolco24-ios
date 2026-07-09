//
//  CompPickerView.swift
//  kolco24
//
//  Флоу выбора гонки/команды — идиоматичный iOS (НЕ порт Android-оверлеев с BackHandler):
//  `.fullScreenCover` → `NavigationStack` (`CompPickerView` → push `TeamPickerView`) → confirmation
//  `.sheet` (`TeamConfirmSheet`). Здесь: контейнер флоу `TeamPickerFlowView` + шаг 1 `CompPickerView`
//  (список гонок: текущие/архив, пилюли статуса, автообновление при открытии, pull-to-refresh).
//
//  Kotlin-референс: `ui/teampicker/CompPickerScreen.kt`. Derived-логика — из `TeamPickerModel`
//  (поверх `Core/Team/TeamPickerLogic.swift`). Дизайн — существующая система (`DesignTokens`).
//

import SwiftUI

/// Контейнер флоу: владеет `TeamPickerModel`, держит `NavigationStack`-путь (стек гонок) и раздаёт
/// `onClose` (закрыть весь cover после подтверждения/отмены).
struct TeamPickerFlowView: View {
    @State var model: TeamPickerModel
    let onClose: () -> Void

    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            CompPickerView(
                model: model,
                onClose: onClose,
                onRaceSelected: { path.append($0) }
            )
            .navigationDestination(for: Int.self) { raceId in
                TeamPickerView(
                    model: model,
                    raceId: raceId,
                    onClose: onClose
                )
            }
        }
        .task { model.start() }
    }
}

// MARK: - Шаг 1 — выбор гонки

struct CompPickerView: View {
    @State var model: TeamPickerModel
    let onClose: () -> Void
    let onRaceSelected: (Int) -> Void

    @State private var showArchive = false

    private var list: [Race] {
        showArchive ? model.split.archive : model.split.current
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                filterChips
                    .padding(.horizontal, DS.hPad)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                if list.isEmpty {
                    emptyCard
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { idx, race in
                            Button { onRaceSelected(race.id) } label: {
                                CompRowView(
                                    race: race,
                                    today: model.today,
                                    isCurrent: race.id == model.selectedRaceId
                                )
                            }
                            .buttonStyle(.plain)
                            if idx < list.count - 1 {
                                Rectangle()
                                    .fill(Color.hairline)
                                    .frame(height: 0.5)
                                    .padding(.leading, DS.hPad + 44 + 12)
                            }
                        }
                    }
                    .background(Color.card)
                    .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
                    .padding(.horizontal, DS.hPad)
                }

                Text("Выберите соревнование — откроется список его команд.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.hPad + 4)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
            }
        }
        .background(Color.paper)
        .navigationTitle("Соревнование")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Закрыть") { onClose() }
            }
        }
        .refreshable { await model.openedCompPicker() }
        .task { await model.openedCompPicker() }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            CompFilterChip(
                label: "Актуальные · \(model.split.current.count)",
                selected: !showArchive
            ) { showArchive = false }
            CompFilterChip(
                label: "Архив · \(model.split.archive.count)",
                selected: showArchive
            ) { showArchive = true }
            Spacer(minLength: 0)
        }
    }

    private var emptyCard: some View {
        Text("Здесь пока пусто")
            .font(.system(size: 15))
            .foregroundStyle(Color.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.hPad)
            .padding(.vertical, 20)
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
            .padding(.horizontal, DS.hPad)
    }
}

// MARK: - Компоненты шага 1

private struct CompFilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                }
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .foregroundStyle(selected ? Color.paper : Color.ink)
            .background(
                Capsule().fill(selected ? Color.ink : Color.clear)
            )
            .overlay(
                Capsule().stroke(Color.hairline, lineWidth: selected ? 0 : 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CompRowView: View {
    let race: Race
    let today: String
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            RaceDateToken(date: race.date)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(race.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if isCurrent { CurrentBadge(text: "ТЕКУЩЕЕ") }
                }
                HStack(spacing: 7) {
                    RaceStatusPillView(pill: raceStatusPill(race, today: today))
                    Text(race.place)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sub)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sub)
        }
        .padding(.horizontal, DS.hPad)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Charcoal-токен даты: amber-месяц над белым днём, обе строки — mono. Фикс-тёмный в обеих темах
/// (белый текст читается), как в Android (`DateToken`).
struct RaceDateToken: View {
    let date: String

    var body: some View {
        let (month, day) = monthDay(date)
        VStack(spacing: 0) {
            Text(month)
                .font(.mono(8.5, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(Color.amber)
            Text(day)
                .font(.mono(17, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .background(
            LinearGradient(colors: [Color.charcoal, Color.charcoalHi],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Пилюля статуса гонки. Регистрация — акцентная (kolcoOrange), остальное — приглушённая.
struct RaceStatusPillView: View {
    let pill: RaceStatusPill

    private var isRegistration: Bool { pill == .registration }

    var body: some View {
        Text(pill.label.uppercased())
            .font(.mono(9.5, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(isRegistration ? Color.kolcoOrange : Color.sub)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill((isRegistration ? Color.kolcoOrange : Color.sub).opacity(0.12))
            )
    }
}

struct CurrentBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.mono(9.5, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(Color.good)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.good.opacity(0.12)))
    }
}

/// `YYYY-MM-DD` → (русский месяц-аббревиатура, день без ведущего нуля). Строковым срезом, как в
/// Android (`monthDay`). Некорректный ввод деградирует безопасно.
func monthDay(_ date: String) -> (month: String, day: String) {
    let months = ["ЯНВ", "ФЕВ", "МАР", "АПР", "МАЙ", "ИЮН",
                  "ИЮЛ", "АВГ", "СЕН", "ОКТ", "НОЯ", "ДЕК"]
    let parts = date.split(separator: "-", omittingEmptySubsequences: false)
    let monthNum = parts.count > 1 ? Int(parts[1]) : nil
    let dayRaw = parts.count > 2 ? String(parts[2]) : ""
    let day = dayRaw.drop { $0 == "0" }
    let abbr = monthNum.flatMap { (1...12).contains($0) ? months[$0 - 1] : nil } ?? ""
    return (abbr, day.isEmpty ? "0" : String(day))
}
