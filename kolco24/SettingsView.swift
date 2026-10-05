//
//  SettingsView.swift
//  kolco24
//
//  Экран «Настройки» (этап 9). Шит из вкладки «Команда» (паттерн «Загрузка данных» → `UploadView`),
//  а не полноэкранный оверлей как на Android. Порт ПОВЕДЕНИЯ `ui/settings/SettingsScreen.kt`: тема,
//  «Очистить трек» (guard «не во время записи»), LAN-тумблер со статусом, скрытая «Отладка» (10 тапов
//  по «Версия»), «Версия». Плюс «Сменить команду» (как на Android: перенесена сюда с вкладки «Команда»)
//  и «Администратор» (этап 10) — оба закрывают шит, флоу поднимает хост в `onDismiss`.
//
//  Вся доменная логика в `SettingsModel`; вьюха только рендерит + держит локальный `debugUnlocked`
//  (per-composition, сбрасывается при закрытии шита) и счётчик тапов версии. Тост «Меню отладки
//  включено» кидается через `AppModel` из окружения (шит наследует env корня).
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// «Язык» ведёт на страницу приложения в настройках iOS (`app-settings:` — без UIKit-константы).
    @Environment(\.openURL) private var openURL
    /// Наследуется из окружения корня — канал тостов для 10-тап разблокировки отладки.
    @Environment(AppModel.self) private var appModel
    let model: SettingsModel
    /// Открыть админ-флоу: хост (`TeamView`) закрывает шит настроек и презентует `fullScreenCover`
    /// с `AdminFlowView` (шит и полноэкранный оверлей нельзя показывать одновременно — оверлей
    /// поднимается после закрытия шита через `onDismiss`).
    var onOpenAdmin: () -> Void = {}
    /// Открыть флоу выбора гонки/команды: как `onOpenAdmin` — хост поднимает `fullScreenCover`
    /// после закрытия шита.
    var onChangeTeam: () -> Void = {}

    /// Секция «Отладка» видна сразу в debug-сборке, иначе — после 10 тапов по «Версия».
    /// Per-composition: сбрасывается при закрытии шита (state вью).
    @State private var debugUnlocked: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    @State private var versionTaps = 0

    /// Подтверждение «Очистить трек?».
    @State private var showClearTrackConfirm = false
    /// Подтверждение «Удалить карту гонки?».
    @State private var showDeleteMapConfirm = false
    /// Какое отладочное действие ждёт подтверждения (nil = никакое).
    @State private var debugConfirm: DebugConfirmKind?

    var body: some View {
        NavigationStack {
            List {
                teamSection
                appearanceSection
                trackSection
                dataSection
                if debugUnlocked {
                    debugSection
                }
                adminSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationTitle(.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.commonDone) { dismiss() }
                }
            }
        }
        .confirmationDialog(
            .settingsClearTrackTitle,
            isPresented: $showClearTrackConfirm,
            titleVisibility: .visible
        ) {
            Button(.commonClear, role: .destructive) { model.clearTrack() }
            Button(.commonCancel, role: .cancel) {}
        } message: {
            Text(.settingsClearTrackMessage)
        }
        .confirmationDialog(
            .settingsDeleteMapTitle,
            isPresented: $showDeleteMapConfirm,
            titleVisibility: .visible
        ) {
            Button(.commonDelete, role: .destructive) { model.deleteRaceMap() }
            Button(.commonCancel, role: .cancel) {}
        } message: {
            Text(.settingsDeleteMapMessage)
        }
        .confirmationDialog(
            debugConfirm?.title ?? "",
            isPresented: Binding(
                get: { debugConfirm != nil },
                set: { if !$0 { debugConfirm = nil } }
            ),
            titleVisibility: .visible,
            presenting: debugConfirm
        ) { kind in
            Button(kind.confirmLabel, role: .destructive) {
                switch kind {
                case .resetTeam: model.resetTeam()
                case .clearDatabase: model.wipeDatabase()
                }
            }
            Button(.commonCancel, role: .cancel) {}
        } message: { kind in
            Text(kind.message)
        }
    }

    // MARK: - Команда

    private var teamSection: some View {
        Section {
            Button {
                dismiss()
                onChangeTeam()
            } label: {
                SettingsRow(
                    systemImage: "arrow.left.arrow.right",
                    iconBg: Color.charcoal,
                    label: String(localized: .teamPickerTitleChange),
                    sub: String(localized: .settingsTeamChangeSub),
                    showChevron: true
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        } header: {
            Text(.tabTeam)
        }
    }

    // MARK: - Внешний вид

    private var appearanceSection: some View {
        @Bindable var model = model
        return Section {
            Picker(.settingsTheme, selection: $model.themeMode) {
                Text(.settingsThemeSystem).tag(ThemeMode.system)
                Text(.settingsThemeLight).tag(ThemeMode.light)
                Text(.settingsThemeDark).tag(ThemeMode.dark)
            }
            .pickerStyle(.menu)
            .tint(Color.kolcoOrange)
            .listRowBackground(Color.card)
            Button {
                if let url = URL(string: "app-settings:") { openURL(url) }
            } label: {
                SettingsRow(
                    systemImage: "globe",
                    iconBg: Color.charcoal,
                    label: String(localized: .settingsLanguage),
                    sub: String(localized: .settingsLanguageCurrent),
                    showChevron: true
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        } header: {
            Text(.settingsAppearance)
        } footer: {
            Text(.settingsLanguageFooter)
        }
    }

    // MARK: - Запись трека

    private var trackSection: some View {
        @Bindable var model = model
        return Section {
            HStack(spacing: 12) {
                SettingsRow(
                    systemImage: "speedometer",
                    iconBg: Color.kolcoOrange,
                    label: String(localized: .mapSpeedLegendLabel),
                    sub: model.colorBySpeedAvailable
                        ? String(localized: .settingsSpeedColorOn)
                        : String(localized: .settingsSpeedColorUnavailable)
                )
                Toggle(.mapSpeedLegendLabel, isOn: $model.colorTrackBySpeed)
                    .labelsHidden()
                    .tint(Color.kolcoOrange)
                    .disabled(!model.colorBySpeedAvailable)
            }
            .listRowBackground(Color.card)

            HStack(spacing: 12) {
                SettingsRow(
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    iconBg: Color.kolcoOrange,
                    label: String(localized: .settingsAllPoints),
                    sub: String(localized: .settingsAllPointsSub)
                )
                Toggle(.settingsAllPoints, isOn: $model.showAllTrackPoints)
                    .labelsHidden()
                    .tint(Color.kolcoOrange)
            }
            .listRowBackground(Color.card)

            Button {
                showClearTrackConfirm = true
            } label: {
                SettingsRow(
                    systemImage: "trash",
                    iconBg: Color.brandRed,
                    label: String(localized: .settingsClearTrack),
                    sub: String(localized: .trackPointsCount(model.trackPointCount)),
                    tint: Color.brandRed
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.clearTrackEnabled)
            .listRowBackground(Color.card)
        } header: {
            Text(.settingsTrackSection)
        }
    }

    // MARK: - Данные

    private var dataSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsRow(
                    systemImage: "wifi",
                    iconBg: Color.good,
                    label: String(localized: .settingsLocalServer),
                    sub: model.localModeBusy ? String(localized: .settingsLocalServerUpdating) : model.localModeSubtitle
                )
                if model.localModeBusy {
                    ProgressView()
                } else {
                    Toggle(.settingsLocalServer, isOn: Binding(
                        get: { model.localModeOn },
                        set: { model.toggleLocalMode($0) }
                    ))
                    .labelsHidden()
                    .tint(Color.kolcoOrange)
                }
            }
            .listRowBackground(Color.card)

            Button {
                showDeleteMapConfirm = true
            } label: {
                SettingsRow(
                    systemImage: "trash",
                    iconBg: Color.brandRed,
                    label: String(localized: .settingsDeleteMap),
                    sub: model.mapFileSizeLabel ?? String(localized: .readinessMapMissingTitle),
                    tint: Color.brandRed
                )
            }
            .buttonStyle(.plain)
            .disabled(model.mapFileSizeLabel == nil)
            .listRowBackground(Color.card)
        } header: {
            Text(.settingsDataSection)
        }
    }

    // MARK: - Отладка (скрытая)

    private var debugSection: some View {
        Section {
            Button {
                debugConfirm = .resetTeam
            } label: {
                SettingsRow(
                    systemImage: "arrow.counterclockwise",
                    iconBg: Color.brandRed,
                    label: String(localized: .settingsDebugResetTeam),
                    sub: String(localized: .settingsDebugResetTeamSub)
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)

            Button {
                debugConfirm = .clearDatabase
            } label: {
                SettingsRow(
                    systemImage: "trash.slash",
                    iconBg: Color.brandRed,
                    label: String(localized: .settingsDebugClearDb),
                    sub: String(localized: .settingsDebugClearDbSub)
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        } header: {
            Text(.settingsDebugSection)
        }
    }

    // MARK: - Администратор (этап 10)

    /// Ряд «Администратор» (всегда видимый, как на Android). Сабтайтл — email активной сессии или «Войти».
    /// Тап: закрыть шит настроек, затем хост поднимет `fullScreenCover` с `AdminFlowView`.
    private var adminSection: some View {
        Section {
            Button {
                dismiss()
                onOpenAdmin()
            } label: {
                SettingsRow(
                    systemImage: "person.badge.key.fill",
                    iconBg: Color.charcoal,
                    label: String(localized: .settingsAdmin),
                    sub: model.adminSubtitle,
                    showChevron: true
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        } header: {
            Text(.settingsOrganizerSection)
        }
    }

    // MARK: - О приложении

    private var aboutSection: some View {
        Section {
            Button {
                guard !debugUnlocked else { return }
                versionTaps += 1
                if versionTaps >= 10 {
                    debugUnlocked = true
                    appModel.toastMessage = String(localized: .settingsDebugUnlocked)
                }
            } label: {
                SettingsRow(
                    systemImage: "info.circle",
                    iconBg: Color.charcoal,
                    label: String(localized: .settingsVersion),
                    sub: model.versionLabel
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        } header: {
            Text(.settingsAboutSection)
        }
    }
}

/// Какое деструктивное отладочное действие ждёт подтверждения (порт `DebugConfirmKind`).
private enum DebugConfirmKind: Identifiable {
    case resetTeam
    case clearDatabase

    var id: Self { self }

    var title: String {
        switch self {
        case .resetTeam: return String(localized: .settingsDebugResetTeamTitle)
        case .clearDatabase: return String(localized: .settingsDebugClearDbTitle)
        }
    }

    var message: String {
        switch self {
        case .resetTeam: return String(localized: .settingsDebugResetTeamMessage)
        case .clearDatabase: return String(localized: .settingsDebugClearDbMessage)
        }
    }

    var confirmLabel: String {
        switch self {
        case .resetTeam: return String(localized: .settingsDebugReset)
        case .clearDatabase: return String(localized: .commonClear)
        }
    }
}

// MARK: - Settings Row

/// Ряд настроек: цветной глиф-аватар, заголовок + сабтайтл. Порт стиля
/// `MiscRowView` из `TeamView` под `List`-секции (без внешних отступов — их даёт `List`).
private struct SettingsRow: View {
    let systemImage: String
    let iconBg: Color
    let label: String
    let sub: String
    var tint: Color = Color.ink
    /// Показать шеврон-дисклоужер справа (ряды-переходы, напр. «Администратор»).
    var showChevron: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconBg)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.sub)
            }
            Spacer(minLength: 8)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sub.opacity(0.45))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
