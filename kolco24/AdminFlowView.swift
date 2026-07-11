//
//  AdminFlowView.swift
//  kolco24
//
//  Админ-флоу организатора (этап 10). Порт ПОВЕДЕНИЯ (не структуры) `ui/admin/AdminScreen.kt`:
//  `fullScreenCover` со своим `NavigationStack` (прецедент `TeamPickerFlowView`), поднимается из
//  ряда «Администратор» в `SettingsView`. Корень `AdminHomeView` ветвится по admin-сессии
//  (подписка на `AppModel.adminSessionUpdates` — единственный потребитель одноконсумерного стрима
//  держателя): `loggedOut` → форма входа (email/пароль, «Войти», спиннер, inline-ошибка из
//  `adminErrorMessage`); `loggedIn` → email + ряды действий.
//
//  Действия «Отметка старта»/«Отметка финиша» пушат `JudgeScanView` (этап 10, задача 9). Ряды
//  «Привязать чип к КП»/«Проверить чип КП»/«Проверить чип участника» — плейсхолдеры (задачи 10 и 12
//  подключат `CheckChipView`/`CheckMemberChipView`/`ProvisioningView`), сейчас видимы и задизейблены.
//
//  Без выбранной команды (`selectedRaceId == nil`) — вместо рядов действий подсказка (гонка неизвестна,
//  судейский `raceId` взять неоткуда).
//

import SwiftUI

/// Пункт навигации админ-флоу. `judge` несёт `eventType` (`start`/`finish`) для `JudgeScanView`.
private enum AdminRoute: Hashable {
    case judge(eventType: String)
}

struct AdminFlowView: View {
    /// Закрыть `fullScreenCover` (хост — `TeamView`).
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            AdminHomeView(onClose: onClose)
                .navigationDestination(for: AdminRoute.self) { route in
                    switch route {
                    case let .judge(eventType):
                        JudgeScanHostView(eventType: eventType)
                    }
                }
        }
    }
}

// MARK: - Корень: форма входа / меню

private struct AdminHomeView: View {
    @Environment(AppModel.self) private var appModel
    let onClose: () -> Void

    /// Локальная копия сессии, ведомая стримом держателя (сид — синхронный снимок; далее `for await`).
    @State private var session: AdminSession = .loggedOut

    // Форма входа.
    @State private var email = ""
    @State private var password = ""
    @State private var loggingIn = false
    @State private var errorText: String?

    // Выход.
    @State private var loggingOut = false

    var body: some View {
        Group {
            switch session {
            case .loggedOut:
                loginForm
            case let .loggedIn(email, _, _):
                menu(email: email)
            }
        }
        .background(Color.paper)
        .navigationTitle("Администратор")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { onClose() }
            }
        }
        .task {
            // Сид синхронным снимком, затем ведём стримом (единственный потребитель одноконсумерного
            // `AsyncStream` держателя — сабтайтл `SettingsModel` читает сессию синхронно).
            session = appModel.currentAdminSession
            for await next in appModel.adminSessionUpdates {
                session = next
            }
        }
    }

    // MARK: Форма входа

    private var loginForm: some View {
        List {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(Color.card)
                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                    .listRowBackground(Color.card)
            } header: {
                Text("Вход организатора")
            } footer: {
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.brandRed)
                }
            }

            Section {
                Button(action: submitLogin) {
                    HStack {
                        Spacer()
                        if loggingIn {
                            ProgressView().tint(.white)
                        } else {
                            Text("Войти")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .disabled(loggingIn || email.isEmpty || password.isEmpty)
                .listRowBackground(canSubmit ? Color.kolcoOrange : Color.sub.opacity(0.3))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.paper)
    }

    private var canSubmit: Bool { !loggingIn && !email.isEmpty && !password.isEmpty }

    private func submitLogin() {
        guard canSubmit else { return }
        loggingIn = true
        errorText = nil
        let email = email
        let password = password
        Task {
            let outcome = await appModel.adminLogin(email: email, password: password)
            loggingIn = false
            // Успех → стрим держателя переведёт `session` в `.loggedIn` (ветка меню). Иначе — inline-ошибка.
            errorText = adminErrorMessage(outcome)
            if outcome == .success {
                self.password = ""
            }
        }
    }

    // MARK: Меню действий

    @ViewBuilder
    private func menu(email: String) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.good)
                            .frame(width: 34, height: 34)
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Вход выполнен")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.sub)
                        Text(email)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.card)
            }

            if appModel.selectedRaceId == nil {
                Section {
                    Text("Выберите команду на вкладке «Команда», чтобы открыть судейские действия — гонка определяется по выбранной команде.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sub)
                        .listRowBackground(Color.card)
                } header: {
                    Text("Действия")
                }
            } else {
                Section {
                    // Провижининг + проверки чипов — задачи 11–12 / 10; сейчас видимы, но задизейблены.
                    AdminActionRow(systemImage: "link.badge.plus", iconBg: Color.charcoal,
                                   label: "Привязать чип к КП", sub: "Скоро", enabled: false)
                    AdminActionRow(systemImage: "magnifyingglass", iconBg: Color.charcoal,
                                   label: "Проверить чип КП", sub: "Скоро", enabled: false)
                    AdminActionRow(systemImage: "person.crop.circle.badge.questionmark", iconBg: Color.charcoal,
                                   label: "Проверить чип участника", sub: "Скоро", enabled: false)
                } header: {
                    Text("Чипы")
                }

                Section {
                    NavigationLink(value: AdminRoute.judge(eventType: "start")) {
                        AdminActionRow(systemImage: "flag.fill", iconBg: Color.good,
                                       label: "Отметка старта", sub: "Сканировать браслеты на старте", enabled: true)
                    }
                    .listRowBackground(Color.card)
                    NavigationLink(value: AdminRoute.judge(eventType: "finish")) {
                        AdminActionRow(systemImage: "flag.checkered", iconBg: Color.brandRed,
                                       label: "Отметка финиша", sub: "Сканировать браслеты на финише", enabled: true)
                    }
                    .listRowBackground(Color.card)
                } header: {
                    Text("Судейские отметки")
                }
            }

            Section {
                Button(action: submitLogout) {
                    HStack {
                        Spacer()
                        if loggingOut {
                            ProgressView()
                        } else {
                            Text("Выйти")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.brandRed)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .disabled(loggingOut)
                .listRowBackground(Color.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.paper)
    }

    private func submitLogout() {
        guard !loggingOut else { return }
        loggingOut = true
        Task {
            await appModel.adminLogout()
            loggingOut = false
            // Стрим держателя переведёт `session` в `.loggedOut` (ветка формы).
        }
    }
}

// MARK: - Ряд действия

/// Ряд меню админа под `List`-секции: цветной глиф-аватар, заголовок + сабтайтл, шеврон.
/// Задизейбленные (плейсхолдеры задач 10–12) приглушены и без шеврона.
private struct AdminActionRow: View {
    let systemImage: String
    let iconBg: Color
    let label: String
    let sub: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(enabled ? iconBg : Color.sub.opacity(0.4))
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(enabled ? Color.ink : Color.sub)
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.sub)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.55)
        .allowsHitTesting(enabled)
    }
}

// MARK: - Хост судейского экрана

/// Строит `JudgeScanModel` для `eventType` из графа (`AppModel.makeJudgeScanModel`) и держит его,
/// пока экран на стеке. `nil` (нет команды) — защитная подсказка (в меню такой ряд недоступен).
private struct JudgeScanHostView: View {
    @Environment(AppModel.self) private var appModel
    let eventType: String
    @State private var model: JudgeScanModel?

    var body: some View {
        Group {
            if let model {
                JudgeScanView(model: model)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.3.sequence")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.sub)
                    Text("Сначала выберите команду")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.paper)
            }
        }
        .task {
            if model == nil { model = appModel.makeJudgeScanModel(eventType: eventType) }
        }
    }
}

// MARK: - Preview

#if DEBUG
private struct AdminFlowPreviewHost: View {
    @State private var appModel: AppModel?

    var body: some View {
        Group {
            if let appModel {
                AdminFlowView(onClose: {})
                    .environment(appModel)
            } else {
                Color.paper
            }
        }
        .task {
            guard appModel == nil else { return }
            guard let env = try? AppEnvironment.inMemory(transport: { _ in
                (Data(), HTTPURLResponse(
                    url: URL(string: "https://preview.invalid")!, statusCode: 500,
                    httpVersion: nil, headerFields: nil)!)
            }) else { return }
            appModel = AppModel(env: env)
        }
    }
}

#Preview("Login (Light)") {
    AdminFlowPreviewHost()
}

#Preview("Login (Dark)") {
    AdminFlowPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
