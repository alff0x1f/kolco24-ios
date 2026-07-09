//
//  kolco24App.swift
//  kolco24
//
//  Created by Ildus Ilistanov on 06.04.2026.
//

import SwiftUI

@main
struct kolco24App: App {
    /// Граф зависимостей (БД, сеть, сторы, репозитории) — создаётся один раз на запуск процесса.
    private let environment: AppEnvironment
    /// Кросс-экранная модель (выбранная команда + refresh-оркестрация).
    @State private var appModel: AppModel

    init() {
        // Хард-гейт: без секретов/БД приложению нечего показывать (fail-fast, как Room `build()`).
        let environment = try! AppEnvironment.makeShared()
        self.environment = environment
        // App.init выполняется на главном потоке при запуске — `AppModel` (@MainActor) собираем здесь.
        _appModel = State(initialValue: MainActor.assumeIsolated { AppModel(env: environment) })
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .task { await appModel.start() }
        }
    }
}
