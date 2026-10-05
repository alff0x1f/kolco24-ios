//
//  AdminFlowView.swift
//  kolco24
//
//  Админ-флоу организатора (этап 10). Порт ПОВЕДЕНИЯ (не структуры) `ui/admin/AdminScreen.kt`:
//  `fullScreenCover` со своим `NavigationStack` (прецедент `TeamPickerFlowView`), поднимается из
//  ряда «Администратор» в `SettingsView`. Сессий две, независимые — cloud и LAN-сервер гонки (он
//  выдаёт свои токены); корень `AdminHomeView` подписан на оба мультиконсумерных стрима держателей.
//  Обе `loggedOut` → форма входа (cloud, плюс LAN только в локальном режиме; inline-ошибка из
//  `adminErrorMessage` / `combinedLoginOutcome`); хоть одна `loggedIn` → строки статуса серверов +
//  ряды действий (если пользователь админ выбранной гонки). «Войти» в строке сервера открывает форму
//  только для него («Назад» — в меню).
//
//  Секции «Чипы КП» и «Браслеты участников» — пары «записать → проверить»: «Привязать чип к КП»
//  (`ProvisioningView`) / «Проверить чип КП» (`CheckChipView`); «Записать браслет»
//  (`MemberProvisioningView`, K24-код типа `0x2`) / «Проверить браслет» (`CheckMemberChipView`).
//  «Отметка старта»/«Отметка финиша» пушат `JudgeScanView` (этап 10, задача 9).
//
//  Без выбранной команды (`selectedRaceId == nil`) — вместо рядов действий подсказка (гонка неизвестна,
//  судейский `raceId` взять неоткуда). Гонки нет в `adminRaceIds` ни одной сессии (`isRaceAdmin`) —
//  вместо рядов «Нет прав администратора на эту гонку».
//

import SwiftUI

/// Пункт навигации админ-флоу. `judge` несёт `eventType` (`start`/`finish`) для `JudgeScanView`.
private enum AdminRoute: Hashable {
    case judge(eventType: String)
    case checkChip
    case checkMemberChip
    case provisioning
    case memberProvisioning
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
                    case .checkChip:
                        CheckChipHostView()
                    case .checkMemberChip:
                        CheckMemberChipHostView()
                    case .provisioning:
                        ProvisioningHostView()
                    case .memberProvisioning:
                        MemberProvisioningHostView()
                    }
                }
        }
    }
}

// MARK: - Корень: форма входа / меню

private struct AdminHomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    let onClose: () -> Void

    /// Локальные копии сессий cloud и LAN, ведомые стримами держателей (сид — синхронный снимок).
    @State private var cloudSession: AdminSession = .loggedOut
    @State private var localSession: AdminSession = .loggedOut
    /// Локальный режим гонки (lease). Опрос: на появлении, смене сессии и возврате в приложение.
    @State private var lanActive = false
    /// Повторный вход на один сервер из меню («Войти» в его строке статуса); `nil` — меню / первый вход.
    @State private var reLoginTarget: AdminServer?

    // Форма входа.
    @State private var email = ""
    @State private var password = ""
    @State private var passwordVisible = false
    @State private var loggingIn = false
    @State private var errorText: String?

    // Выход.
    @State private var loggingOut = false

    private var anyLoggedIn: Bool { cloudSession != .loggedOut || localSession != .loggedOut }
    private var reLoginShown: Bool { reLoginTarget != nil && anyLoggedIn }
    private var canAdminSelectedRace: Bool {
        appModel.selectedRaceId.map { isRaceAdmin(raceId: $0, cloud: cloudSession, local: localSession) } ?? false
    }

    var body: some View {
        Group {
            if !anyLoggedIn || reLoginTarget != nil {
                loginForm(target: anyLoggedIn ? reLoginTarget : nil)
            } else {
                menu
            }
        }
        .background(Color.paper)
        .navigationTitle(.settingsAdmin)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(reLoginShown)
        .toolbar {
            if reLoginShown {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonBack) { reLoginTarget = nil }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(.commonDone) { onClose() }
            }
        }
        .task {
            cloudSession = appModel.currentCloudAdminSession
            for await next in appModel.cloudAdminSessionUpdates {
                cloudSession = next
            }
        }
        .task {
            localSession = appModel.currentLocalAdminSession
            for await next in appModel.localAdminSessionUpdates {
                localSession = next
            }
        }
        .onAppear { lanActive = appModel.isLanActive }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { lanActive = appModel.isLanActive }
        }
        .onChange(of: cloudSession) { _, _ in sessionsChanged() }
        .onChange(of: localSession) { _, _ in sessionsChanged() }
    }

    /// Форма повторного входа закрывается, когда появилась сессия её сервера — от этой формы или от
    /// старой попытки в полёте, — а не по колбэку успеха, который могла бы дёрнуть и устаревшая попытка.
    /// Без обеих сессий цель тоже сбрасывается: полная форма берёт верх.
    private func sessionsChanged() {
        lanActive = appModel.isLanActive
        let targetSession: AdminSession? = switch reLoginTarget {
        case .cloud: cloudSession
        case .lan: localSession
        case nil: nil
        }
        if case .loggedIn = targetSession { reLoginTarget = nil }
        if !anyLoggedIn { reLoginTarget = nil }
    }

    // MARK: Форма входа

    /// [target] `nil` — первый вход: cloud, плюс LAN только в локальном режиме. Иначе — только этот сервер.
    private func loginForm(target: AdminServer?) -> some View {
        List {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(Color.card)
                HStack {
                    Group {
                        if passwordVisible {
                            TextField(String(localized: .adminLoginPassword), text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(String(localized: .adminLoginPassword), text: $password)
                        }
                    }
                    .textContentType(.password)
                    Button {
                        passwordVisible.toggle()
                    } label: {
                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(Color.sub)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(passwordVisible ? .adminLoginHidePassword : .adminLoginShowPassword))
                }
                .listRowBackground(Color.card)
            } header: {
                Text(loginTitle(target))
            } footer: {
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.brandRed)
                }
            }

            Section {
                Button { submitLogin(target: target) } label: {
                    HStack {
                        Spacer()
                        if loggingIn {
                            ProgressView().tint(.white)
                        } else {
                            Text(.adminRowSignIn)
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

    private func loginTitle(_ target: AdminServer?) -> String {
        switch target {
        case .cloud: String(localized: .adminLoginTitleCloud)
        case .lan: String(localized: .adminLoginTitleLan)
        case nil: String(localized: .adminLoginTitleOrganizer)
        }
    }

    private var canSubmit: Bool { !loggingIn && !email.isEmpty && !password.isEmpty }

    private func submitLogin(target: AdminServer?) {
        guard canSubmit else { return }
        loggingIn = true
        errorText = nil
        let email = email.trimmingCharacters(in: .whitespaces)
        let password = password
        Task {
            let outcome = await appModel.adminLogin(server: target, email: email, password: password)
            loggingIn = false
            // Успех → стримы держателей переведут сессии (ветка меню). Иначе — inline-ошибка.
            guard let outcome else {
                errorText = String(localized: .adminLoginEnableLocalMode)
                return
            }
            errorText = adminErrorMessage(outcome)
            if outcome == .success {
                self.password = ""
            }
        }
    }

    /// Открыть форму входа на один сервер; email подставляется из уже активной сессии.
    private func openReLogin(_ server: AdminServer) {
        if case let .loggedIn(email, _, _, _) = cloudSession {
            self.email = email
        } else if case let .loggedIn(email, _, _, _) = localSession {
            self.email = email
        }
        password = ""
        errorText = nil
        reLoginTarget = server
    }

    // MARK: Меню действий

    private var menu: some View {
        List {
            Section {
                ServerStatusRow(label: "Cloud", session: cloudSession, loggedOutText: String(localized: .adminStatusNotSignedIn),
                                onLogin: { openReLogin(.cloud) })
                    .listRowBackground(Color.card)
                ServerStatusRow(label: "LAN", session: localSession,
                                loggedOutText: lanActive ? String(localized: .adminStatusNotSignedIn) : String(localized: .adminStatusEnableLocalMode),
                                onLogin: lanActive ? { openReLogin(.lan) } : nil)
                    .listRowBackground(Color.card)
            } header: {
                Text(.adminSignedIn)
            }

            if appModel.selectedRaceId == nil {
                Section {
                    Text(.adminChooseTeamHint)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sub)
                        .listRowBackground(Color.card)
                } header: {
                    Text(.adminActions)
                }
            } else if !canAdminSelectedRace {
                Section {
                    Text(.adminNoRights)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sub)
                        .listRowBackground(Color.card)
                } header: {
                    Text(.adminActions)
                }
            } else {
                Section {
                    NavigationLink(value: AdminRoute.provisioning) {
                        AdminActionRow(systemImage: "link.badge.plus", iconBg: Color.charcoal,
                                       label: String(localized: .adminActionBindCpChip), sub: String(localized: .adminActionBindCpChipSub), enabled: true)
                    }
                    .listRowBackground(Color.card)
                    NavigationLink(value: AdminRoute.checkChip) {
                        AdminActionRow(systemImage: "magnifyingglass", iconBg: Color.charcoal,
                                       label: String(localized: .adminActionCheckCpChip), sub: String(localized: .adminActionCheckCpChipSub), enabled: true)
                    }
                    .listRowBackground(Color.card)
                } header: {
                    Text(.adminSectionCpChips)
                }

                Section {
                    NavigationLink(value: AdminRoute.memberProvisioning) {
                        AdminActionRow(systemImage: "person.badge.key.fill", iconBg: Color.charcoal,
                                       label: String(localized: .adminActionWriteWristband), sub: String(localized: .adminActionWriteWristbandSub), enabled: true)
                    }
                    .listRowBackground(Color.card)
                    NavigationLink(value: AdminRoute.checkMemberChip) {
                        AdminActionRow(systemImage: "person.crop.circle.badge.questionmark", iconBg: Color.charcoal,
                                       label: String(localized: .adminActionCheckWristband), sub: String(localized: .adminActionCheckWristbandSub), enabled: true)
                    }
                    .listRowBackground(Color.card)
                } header: {
                    Text(.adminSectionWristbands)
                }

                Section {
                    NavigationLink(value: AdminRoute.judge(eventType: "start")) {
                        AdminActionRow(systemImage: "flag.fill", iconBg: Color.good,
                                       label: String(localized: .judgeTitleStart), sub: String(localized: .judgeStartSub), enabled: true)
                    }
                    .listRowBackground(Color.card)
                    NavigationLink(value: AdminRoute.judge(eventType: "finish")) {
                        AdminActionRow(systemImage: "flag.checkered", iconBg: Color.brandRed,
                                       label: String(localized: .judgeTitleFinish), sub: String(localized: .judgeFinishSub), enabled: true)
                    }
                    .listRowBackground(Color.card)
                } header: {
                    Text(.adminSectionJudgeScans)
                }
            }

            Section {
                Button(action: submitLogout) {
                    HStack {
                        Spacer()
                        if loggingOut {
                            ProgressView()
                        } else {
                            Text(.adminSignOut)
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
            // Стримы держателей переведут сессии в `.loggedOut` (ветка формы).
        }
    }
}

// MARK: - Строка статуса сервера

/// Сессия одного сервера: «Cloud · email» или «Cloud · нет входа» с необязательной «Войти».
private struct ServerStatusRow: View {
    let label: String
    let session: AdminSession
    let loggedOutText: String
    let onLogin: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(loggedIn ? Color.good : Color.sub.opacity(0.4))
                    .frame(width: 34, height: 34)
                Image(systemName: loggedIn ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sub)
                Text(detail)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(loggedIn ? Color.ink : Color.sub)
            }
            Spacer()
            if !loggedIn, let onLogin {
                Button(.adminRowSignIn, action: onLogin)
                    .buttonStyle(.borderless)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kolcoOrange)
            }
        }
        .padding(.vertical, 2)
    }

    private var loggedIn: Bool { session != .loggedOut }

    private var detail: String {
        if case let .loggedIn(email, _, _, _) = session { return email }
        return loggedOutText
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
                JudgeScanView(model: model, clockStatus: appModel.clockStatus)
            } else {
                AdminNoTeamPlaceholder()
            }
        }
        .task {
            if model == nil { model = appModel.makeJudgeScanModel(eventType: eventType) }
        }
    }
}

/// Строит `ChipCheckModel` из графа (`AppModel.makeChipCheckModel`) и держит его, пока экран на стеке.
private struct CheckChipHostView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: ChipCheckModel?

    var body: some View {
        Group {
            if let model {
                CheckChipView(model: model)
            } else {
                AdminNoTeamPlaceholder()
            }
        }
        .task { if model == nil { model = appModel.makeChipCheckModel() } }
    }
}

/// Строит `MemberChipCheckModel` из графа (`AppModel.makeMemberChipCheckModel`) и держит его.
private struct CheckMemberChipHostView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: MemberChipCheckModel?

    var body: some View {
        Group {
            if let model {
                CheckMemberChipView(model: model)
            } else {
                AdminNoTeamPlaceholder()
            }
        }
        .task { if model == nil { model = appModel.makeMemberChipCheckModel() } }
    }
}

/// Строит `ProvisioningModel` из графа (`AppModel.makeProvisioningModel`) и держит его, пока экран
/// на стеке. На 401 (`closeRequested`) — авто-возврат в форму логина (сессия уже отозвана).
private struct ProvisioningHostView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProvisioningModel?

    var body: some View {
        Group {
            if let model {
                ProvisioningView(model: model)
                    .onChange(of: model.closeRequested) { _, requested in
                        if requested { dismiss() }
                    }
            } else {
                AdminNoTeamPlaceholder()
            }
        }
        .task { if model == nil { model = appModel.makeProvisioningModel() } }
    }
}

/// Строит `MemberProvisioningModel` из графа (`AppModel.makeMemberProvisioningModel`) и держит его,
/// пока экран на стеке. На 401 (`closeRequested`) — авто-возврат в форму логина (сессия уже отозвана).
private struct MemberProvisioningHostView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var model: MemberProvisioningModel?

    var body: some View {
        Group {
            if let model {
                MemberProvisioningView(model: model)
                    .onChange(of: model.closeRequested) { _, requested in
                        if requested { dismiss() }
                    }
            } else {
                AdminNoTeamPlaceholder()
            }
        }
        .task { if model == nil { model = appModel.makeMemberProvisioningModel() } }
    }
}

/// Защитная подсказка «нет выбранной команды» (в меню такой ряд недоступен — гонка неизвестна).
private struct AdminNoTeamPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 40))
                .foregroundStyle(Color.sub)
            Text(.marksEmptyChooseTeamFirst)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
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
