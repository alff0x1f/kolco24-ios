//
//  TeamConfirmSheet.swift
//  kolco24
//
//  Шаг 3 флоу — подтверждающий лист перед сменой команды. Порт `ui/teampicker/TeamSwitchSheet.kt`,
//  но идиоматично: `.sheet` c `presentationDetents([.medium])` вместо `ModalBottomSheet`. Показывает
//  токен/название/категорию команды, ростер (имена участников) и оранжевую CTA «Выбрать команду».
//  `onConfirm` коммитит выбор (хост персистит через `AppModel.selectTeam` и закрывает весь cover);
//  `onCancel` закрывает только лист.
//

import SwiftUI

struct TeamConfirmSheet: View {
    let team: Team
    let category: Category?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TeamTokenView(text: teamToken(team), size: 60)
                .padding(.top, 28)

            Text(displayTeamName(team))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            Text(peopleLine(category: category, ucount: team.ucount))
                .font(.system(size: 14))
                .foregroundStyle(Color.sub)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            if !team.members.isEmpty {
                VStack(spacing: 8) {
                    ForEach(team.members.sorted { $0.numberInTeam < $1.numberInTeam }, id: \.numberInTeam) { member in
                        Text(member.name)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.ink)
                    }
                }
                .padding(.top, 20)
            }

            Spacer(minLength: 24)

            Button(action: onConfirm) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    Text("Выбрать команду").font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .foregroundStyle(.white)
                .background(Color.kolcoOrange)
                .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
            }

            Button("Отмена", action: onCancel)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.paper)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// `Identifiable`-конформанс для `.sheet(item:)` — `Team` уже несёт серверный `id`. Стандартный
/// протокол Swift (не SwiftUI), тот же модуль — держим в UI-слое, чтобы `Model/` не трогать.
extension Team: Identifiable {}
