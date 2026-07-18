//
//  ContentView.swift
//  kolco24
//
//  Created by Ildus Ilistanov on 06.04.2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    /// Фаза сцены — рестарт 5-мин цикла выгрузки на `.active`, отмена на фоне (этап 6, аналог
    /// `repeatOnLifecycle(STARTED)`).
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    /// Флоу выбора гонки/команды (`.fullScreenCover`). Точки входа: CTA empty-состояний вкладок и
    /// строка «Сменить команду» в `TeamView`.
    @State private var showPicker = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    MarksView(
                        onChooseTeam: { showPicker = true },
                        onBindChips: { selectedTab = 3 }
                    )
                }
                .tabItem { Label("Отметки", systemImage: "flag.fill") }
                .tag(0)
                NavigationStack { LegendView(onChooseTeam: { showPicker = true }) }
                    .tabItem { Label("Легенда", systemImage: "map.fill") }
                    .tag(1)
                NavigationStack {
                    MapTabView(onChooseTeam: { showPicker = true })
                }
                .tabItem { Label("Карта", systemImage: "mappin.and.ellipse") }
                .tag(2)
                NavigationStack {
                    TeamView(onChooseTeam: { showPicker = true })
                }
                .tabItem { Label("Команда", systemImage: "person.3.fill") }
                .tag(3)
            }
            .tint(Color.kolcoOrange)
            .onChange(of: selectedTab) {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            // Глобальная плашка сдвига часов над вкладками (этап 11) — только на `.skewed`, иначе
            // нулевая высота (паритет с Android; полноэкранные каверы её не показывают). Анимация
            // появления — как у тоста.
            .safeAreaInset(edge: .top, spacing: 0) {
                GlobalClockBanner(status: appModel.clockStatus)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appModel.clockStatus)
            }

            // Тост ошибки refresh — overlay над таб-баром, авто-скрытие ~3 с.
            if let toast = appModel.toastMessage {
                ToastBanner(message: toast)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appModel.toastMessage)
        .task(id: appModel.toastMessage) {
            guard appModel.toastMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            appModel.toastMessage = nil
        }
        .fullScreenCover(isPresented: $showPicker) {
            TeamPickerFlowView(
                model: appModel.makeTeamPickerModel(),
                onClose: { showPicker = false }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            appModel.scenePhaseChanged(isActive: phase == .active)
        }
        // Этап 9: тема приложения. `system` → `nil` (следуем OS), `light`/`dark` — переопределение.
        // Единственное место, где SwiftUI касается `ThemeMode` — `Core/` остаётся SwiftUI-free.
        .preferredColorScheme(appModel.themeMode.colorScheme)
    }
}

/// UI-маппер `ThemeMode → ColorScheme?` (этап 9). Живёт в UI-слое, не в `Core/`/`AppModel` —
/// grep-инвариант «`Core/` и `App/`-модели свободны от SwiftUI».
extension ThemeMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
