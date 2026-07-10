//
//  SettingsView.swift
//  kolco24
//
//  Экран «Настройки» (этап 9). Шит из вкладки «Команда» (паттерн «Загрузка данных» → `UploadView`),
//  а не полноэкранный оверлей как на Android. Порт ПОВЕДЕНИЯ `ui/settings/SettingsScreen.kt`: тема,
//  «Очистить трек» (guard «не во время записи»), LAN-тумблер со статусом, скрытая «Отладка» (10 тапов
//  по «Версия»), «Версия». Секции «Сменить команду» (уже есть в `TeamView`) и «Администратор» (этап 10)
//  сюда не переносятся.
//
//  Вся доменная логика в `SettingsModel`; вьюха только рендерит + держит локальный `debugUnlocked`
//  (per-composition, сбрасывается при закрытии шита) и счётчик тапов версии. Тост «Меню отладки
//  включено» кидается через `AppModel` из окружения (шит наследует env корня).
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// Наследуется из окружения корня — канал тостов для 10-тап разблокировки отладки.
    @Environment(AppModel.self) private var appModel
    let model: SettingsModel

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
    /// Какое отладочное действие ждёт подтверждения (nil = никакое).
    @State private var debugConfirm: DebugConfirmKind?

    var body: some View {
        NavigationStack {
            List {
                appearanceSection
                trackSection
                dataSection
                if debugUnlocked {
                    debugSection
                }
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Очистить трек?",
            isPresented: $showClearTrackConfirm,
            titleVisibility: .visible
        ) {
            Button("Очистить", role: .destructive) { model.clearTrack() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все записанные точки этой команды будут удалены без возможности восстановления.")
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
            Button("Отмена", role: .cancel) {}
        } message: { kind in
            Text(kind.message)
        }
    }

    // MARK: - Внешний вид

    private var appearanceSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Тема", selection: $model.themeMode) {
                Text("Системная").tag(ThemeMode.system)
                Text("Светлая").tag(ThemeMode.light)
                Text("Тёмная").tag(ThemeMode.dark)
            }
            .pickerStyle(.menu)
            .tint(Color.kolcoOrange)
            .listRowBackground(Color.card)
        } header: {
            Text("Внешний вид")
        }
    }

    // MARK: - Запись трека

    private var trackSection: some View {
        Section {
            Button {
                showClearTrackConfirm = true
            } label: {
                SettingsRow(
                    systemImage: "trash",
                    iconBg: Color.brandRed,
                    label: "Очистить трек",
                    sub: pointsLabel(model.trackPointCount),
                    tint: Color.brandRed
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.clearTrackEnabled)
            .listRowBackground(Color.card)
        } header: {
            Text("Запись трека")
        }
    }

    // MARK: - Данные

    private var dataSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsRow(
                    systemImage: "wifi",
                    iconBg: Color.good,
                    label: "Локальный сервер (Wi-Fi гонки)",
                    sub: model.localModeBusy ? "Обновление…" : model.localModeSubtitle
                )
                if model.localModeBusy {
                    ProgressView()
                } else {
                    Toggle("", isOn: Binding(
                        get: { model.localModeOn },
                        set: { model.toggleLocalMode($0) }
                    ))
                    .labelsHidden()
                    .tint(Color.kolcoOrange)
                }
            }
            .listRowBackground(Color.card)
        } header: {
            Text("Данные")
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
                    label: "Сбросить команду",
                    sub: "Debug: вернуться к выбору команды"
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
                    label: "Очистить базу данных",
                    sub: "Debug: удалить гонки, команды, легенду и ETag"
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        } header: {
            Text("Отладка")
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
                    appModel.toastMessage = "Меню отладки включено"
                }
            } label: {
                SettingsRow(
                    systemImage: "info.circle",
                    iconBg: Color.charcoal,
                    label: "Версия",
                    sub: model.versionLabel
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.card)
        } header: {
            Text("О приложении")
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
        case .resetTeam: return "Сбросить команду?"
        case .clearDatabase: return "Очистить базу данных?"
        }
    }

    var message: String {
        switch self {
        case .resetTeam: return "Текущая команда будет сброшена — придётся выбрать её заново."
        case .clearDatabase: return "Все локальные данные (гонки, команды, легенда, ETag) будут удалены и загружены заново."
        }
    }

    var confirmLabel: String {
        switch self {
        case .resetTeam: return "Сбросить"
        case .clearDatabase: return "Очистить"
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
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
