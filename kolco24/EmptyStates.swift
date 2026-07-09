//
//  EmptyStates.swift
//  kolco24
//
//  Переиспользуемые пустые состояния «команда не выбрана / команда исчезла». Порт
//  `ui/teampicker/TeamEmptyContent.kt`: charcoal-иллюстрация с пунктирным оранжевым кольцом и
//  красным свечением, заголовок, пояснение и оранжевая CTA «Выбрать команду» → флоу выбора.
//  Флаг `missing` подменяет копирайт на случай «команда снялась/удалена с сервера» (выбор сохранён).
//
//  Используется вкладкой «Команда» (empty/missing) и — как онбординг «выбери команду» — вкладками
//  «Легенда»/«Отметки» (этапы 6–7). Дизайн — существующая система (`DesignTokens`).
//

import SwiftUI

/// Пустое состояние «нет выбранной команды». `missing == true` — «команда исчезла с сервера».
struct TeamEmptyState: View {
    var missing: Bool = false
    let onChooseTeam: () -> Void

    private var title: String {
        missing ? "Команда больше не зарегистрирована" : "Команда не выбрана"
    }

    private var message: String {
        if missing {
            return "Выбранная команда снялась или удалена из списка. Выберите команду заново, чтобы продолжить отмечаться."
        }
        return "Отметки на КП засчитываются по NFC-чипам участников. Выберите команду, чтобы отмечаться на дистанции и видеть общий счёт."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            EmptyTeamIllustration()

            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.horizontal, DS.hPad)

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Color.sub)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, DS.hPad + 8)

            Spacer(minLength: 24)

            Button(action: onChooseTeam) {
                HStack(spacing: 8) {
                    Image(systemName: "person.3.fill").font(.system(size: 16, weight: .semibold))
                    Text("Выбрать команду").font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(.white)
                .background(Color.kolcoOrange)
                .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
            }
            .padding(.horizontal, DS.hPad)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    }
}

/// Charcoal-круг с красным свечением и групповым глифом внутри пунктирного оранжевого кольца
/// (рифмуется с герой-карточкой). Фикс-тёмный в обеих темах — белый глиф читается всегда.
private struct EmptyTeamIllustration: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    Color.kolcoOrange.opacity(0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 6])
                )
                .frame(width: 132, height: 132)

            ZStack {
                LinearGradient(
                    colors: [Color(hex: "1D242D"), Color(hex: "2A333E")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.brandRed.opacity(0.45), Color.brandRed.opacity(0)],
                    center: .topTrailing, startRadius: 0, endRadius: 90
                )
                Image(systemName: "person.3.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
            }
            .frame(width: 104, height: 104)
            .clipShape(Circle())
        }
    }
}

#Preview("Empty") {
    TeamEmptyState(onChooseTeam: {})
}

#Preview("Missing") {
    TeamEmptyState(missing: true, onChooseTeam: {})
}
