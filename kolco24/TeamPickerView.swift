//
//  TeamPickerView.swift
//  kolco24
//
//  Шаг 2 флоу — выбор команды одной гонки. Порт ПОВЕДЕНИЯ `ui/teampicker/TeamPickerScreen.kt`:
//  карточка контекста гонки (+ «Изменить» → назад), поиск (`.searchable` поверх `filterTeams`),
//  список команд, сгруппированный по категориям, состояния `PickerLoad` (при непустом кэше ошибка —
//  инлайн-баннер, список остаётся). Тап по команде → подтверждающий `.sheet` (`TeamConfirmSheet`).
//
//  Derived — из `TeamPickerModel` (поверх `Core/Team/TeamPickerLogic.swift`).
//

import SwiftUI

struct TeamPickerView: View {
    @Bindable var model: TeamPickerModel
    let raceId: Int
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmTeam: Team?

    private var title: String {
        model.selectedTeamId != nil ? "Сменить команду" : "Выбор команды"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CompContextCard(race: model.pickerRace) { dismiss() }
                    .padding(.horizontal, DS.hPad)
                    .padding(.top, 8)

                content
            }
            .padding(.bottom, 24)
        }
        .background(Color.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchQuery, prompt: "Название или номер команды")
        .refreshable { await model.refreshTeams() }
        .task { await model.raceSelected(raceId) }
        .sheet(item: $confirmTeam) { team in
            TeamConfirmSheet(
                team: team,
                category: model.category(for: team),
                onConfirm: {
                    Task {
                        await model.confirm(raceId: raceId, teamId: team.id)
                        onClose()
                    }
                },
                onCancel: { confirmTeam = nil }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.teams.isEmpty {
            if !model.teamsLoaded || model.load == .loading {
                ProgressView()
                    .padding(.top, 40)
            } else {
                emptyState
            }
        } else {
            if let banner = staleBanner {
                InlineBanner(text: banner)
                    .padding(.horizontal, DS.hPad)
                    .padding(.top, 12)
            }
            Text("Зарегистрированные · \(model.teams.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.sub)
                .textCase(.uppercase)
                .tracking(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.hPad + 4)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if model.sections.isEmpty {
                Text("Ничего не найдено")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.hPad)
                    .padding(.vertical, 20)
                    .background(Color.card)
                    .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
                    .padding(.horizontal, DS.hPad)
            } else {
                ForEach(model.sections) { section in
                    sectionView(section)
                }
                Text("Выбор определяет, чьи NFC-чипы засчитываются на КП.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.hPad + 4)
                    .padding(.top, 8)
            }
        }
    }

    private func sectionView(_ section: TeamPickerModel.TeamSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(categoryTitle(section.category))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.sub)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, DS.hPad + 4)
                .padding(.top, 16)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(section.teams.enumerated()), id: \.element.id) { idx, team in
                    Button { confirmTeam = team } label: {
                        TeamPickRowView(
                            team: team,
                            category: section.category,
                            isCurrent: team.id == model.selectedTeamId
                        )
                    }
                    .buttonStyle(.plain)
                    if idx < section.teams.count - 1 {
                        Rectangle()
                            .fill(Color.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, DS.hPad + 40 + 12)
                    }
                }
            }
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
            .padding(.horizontal, DS.hPad)
        }
    }

    private func categoryTitle(_ category: Category?) -> String {
        guard let category else { return "Без категории" }
        let name = category.shortName.isEmpty ? category.name : category.shortName
        return name.isEmpty ? "Без категории" : name
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.load {
        case .forbidden:
            PickerStatusCard(
                title: "Обновите приложение",
                message: "Текущая версия больше не поддерживается сервером."
            )
        case .offline, .httpError:
            PickerStatusCard(
                title: "Не удалось загрузить команды",
                message: "Проверьте соединение и попробуйте ещё раз.",
                retryLabel: "Повторить",
                onRetry: { Task { await model.refreshTeams() } }
            )
        default:
            Text("Пока никто не зарегистрирован")
                .font(.system(size: 15))
                .foregroundStyle(Color.sub)
                .padding(.horizontal, DS.hPad)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Инлайн-предупреждение при непустом кэше и ошибке refresh (список остаётся видимым).
    private var staleBanner: String? {
        guard !model.teams.isEmpty else { return nil }
        switch model.load {
        case .offline, .httpError: return "Нет сети — показан сохранённый список"
        case .forbidden: return "Требуется обновление приложения"
        default: return nil
        }
    }
}

// MARK: - Компоненты шага 2

/// Карточка контекста гонки: flag-токен, название, «дата · место», «Изменить» → назад к шагу 1.
private struct CompContextCard: View {
    let race: Race?
    let onChangeRace: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "flag.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.charcoal)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(race?.name ?? "—")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let race {
                    Text("\(shortDate(race.date)) · \(race.place)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sub)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("Изменить", action: onChangeRace)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.kolcoOrange)
        }
        .padding(.horizontal, DS.hPad)
        .padding(.vertical, 11)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
    }
}

private struct TeamPickRowView: View {
    let team: Team
    let category: Category?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            TeamTokenView(text: teamToken(team))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayTeamName(team))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if isCurrent { CurrentBadge(text: "ТЕКУЩАЯ") }
                }
                Text(peopleLine(category: category, ucount: team.ucount))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sub)
                    .lineLimit(1)
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

/// Серый squircle-токен с mono-номером/монограммой команды. Общий с `TeamConfirmSheet`.
struct TeamTokenView: View {
    let text: String
    var size: CGFloat = 40

    var body: some View {
        Text(text)
            .font(.mono(size * 0.35, weight: .bold))
            .foregroundStyle(Color.ink)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color.hairline.opacity(0.6), Color.hairline],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
    }
}

private struct InlineBanner: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.hPad)
            .padding(.vertical, 12)
            .background(Color.amber.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
    }
}

private struct PickerStatusCard: View {
    let title: String
    let message: String
    var retryLabel: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.sub)
            if let retryLabel, let onRetry {
                Button(retryLabel, action: onRetry)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.kolcoOrange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, DS.hPad)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal, DS.hPad)
        .padding(.top, 12)
    }
}

/// «10 окт» из `YYYY-MM-DD` строковым срезом (порт `shortDate` из `TeamPickerScreen.kt`).
func shortDate(_ date: String) -> String {
    let (month, day) = monthDay(date)
    if month.isEmpty { return date }
    return "\(day) \(month.lowercased())"
}
