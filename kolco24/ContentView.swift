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
                        onBindChips: { selectedTab = 2 }
                    )
                }
                .tabItem { Label("Отметки", systemImage: "flag.fill") }
                .tag(0)
                NavigationStack { LegendView(onChooseTeam: { showPicker = true }) }
                    .tabItem { Label("Легенда", systemImage: "map.fill") }
                    .tag(1)
                NavigationStack {
                    TeamView(onChooseTeam: { showPicker = true })
                }
                .tabItem { Label("Команда", systemImage: "person.3.fill") }
                .tag(2)
            }
            .tint(Color.kolcoOrange)
            .onChange(of: selectedTab) {
                UISelectionFeedbackGenerator().selectionChanged()
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
    }
}
