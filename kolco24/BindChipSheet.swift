//
//  BindChipSheet.swift
//  kolco24
//
//  Лист привязки NFC-браслета к участнику (этап 5, задача 9). Порт UI `ui/team/BindChipSheet.kt`:
//  рендерит состояние `TeamModel.BindSheetState` (waiting/poolNotReady/notInPool/alreadyBound/success),
//  на `alreadyBound` показывает «Перепривязать?» с подтверждением (`confirmReassign`), на `success` —
//  автозакрытие ~900 мс. Вход — тап по участнику без чипа в `TeamView`; хост открывает одноразовую
//  NFC-сессию через `TeamModel.beginBind(member:)`, любое закрытие → `cancelBind`.
//
//  CoreNFC тут не импортируется (сканер живёт в модели/`Nfc/`); чистая SwiftUI-вьюха над моделью.
//

import SwiftUI

struct BindChipSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: TeamModel
    let member: TeamMemberItem

    /// Автозакрытие после успешной привязки (порт `LaunchedEffect(sheetState){ delay(900) }`).
    private static let successHold: Duration = .milliseconds(900)

    private var isSuccess: Bool {
        if case .success = model.bindState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.sub.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 20)

            Text("ПРИВЯЗАТЬ ЧИП")
                .font(.mono(10, weight: .bold))
                .foregroundStyle(Color.sub)
                .tracking(1.2)

            Text(member.name)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            stateContent
                .padding(.top, 24)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 24)

            Button(isSuccess ? "Готово" : "Отмена") { dismiss() }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Color.paper)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .onChange(of: isSuccess) { _, success in
            guard success else { return }
            Task {
                try? await Task.sleep(for: BindChipSheet.successHold)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.bindState {
        case .waiting:
            iconBadge(system: "wave.3.right", tint: Color.kolcoOrange)
            statusTitle("Поднесите чип к телефону")
            statusBody("Браслет участника нужно поднести к задней панели телефона.")
        case .poolNotReady:
            ZStack {
                Circle().fill(Color.cardElevated).frame(width: 72, height: 72)
                ProgressView().tint(Color.kolcoOrange)
            }
            statusTitle("Загружаем список участников")
            statusBody("Данные ещё не загружены. Поднесите чип снова через несколько секунд.")
        case let .notInPool(uid):
            iconBadge(system: "exclamationmark.triangle.fill", tint: Color.brandRed, filled: false)
            statusTitle("Чип не из этого комплекта")
            statusDetail(uid)
            statusBody("Этот чип не зарегистрирован для гонки. Привязка не сохранена.")
        case let .alreadyBound(uid, participantNumber):
            iconBadge(system: "exclamationmark.triangle.fill", tint: Color.kolcoOrange, filled: false)
            statusTitle("Чип уже привязан")
            statusDetail("№\(participantNumber) · \(uid)")
            statusBody("Этот чип закреплён за другим участником. Перепривязать его к «\(member.name)»?")
            Button("Перепривязать") {
                Task { await model.confirmReassign() }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.kolcoOrange)
            .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
            .padding(.top, 20)
        case let .success(participantNumber):
            iconBadge(system: "checkmark.circle.fill", tint: Color.good, filled: false)
            statusTitle("Чип привязан")
            statusDetail("№\(participantNumber)")
        }
    }

    // MARK: - Кусочки

    private func iconBadge(system: String, tint: Color, filled: Bool = true) -> some View {
        Group {
            if filled {
                ZStack {
                    Circle().fill(Color.cardElevated).frame(width: 72, height: 72)
                    Image(systemName: system)
                        .font(.system(size: 30))
                        .foregroundStyle(tint)
                }
            } else {
                Image(systemName: system)
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
            }
        }
    }

    private func statusTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.center)
            .padding(.top, 16)
    }

    private func statusDetail(_ text: String) -> some View {
        Text(text)
            .font(.mono(13, weight: .medium))
            .foregroundStyle(Color.sub)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private func statusBody(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Color.sub)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
    }
}
