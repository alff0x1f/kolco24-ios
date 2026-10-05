//
//  RefreshErrorMessage.swift
//  kolco24
//
//  Чистый маппинг исхода pull-to-refresh в текст тоста, либо `nil`, когда
//  показывать нечего. Kotlin-источник: `refreshErrorMessage` из
//  `ui/common/PullToRefresh.kt`. Никакого UIKit/SwiftUI.
//
//  Успех (`updated`/`notModified`) молчалив — список обновляется сам через
//  observation. `skipped` (cloud-fetch пропущен из-за пина гонки на LAN) — тоже
//  молчалив, это не ошибка. Только failure-ветки возвращают текст.
//

/// Текст тоста для исхода refresh, либо `nil` для молчаливых исходов. Порт
/// `refreshErrorMessage(RefreshResult): String?` 1:1.
func refreshErrorMessage(_ result: RefreshResult) -> String? {
    switch result {
    case .updated, .notModified, .skipped:
        return nil
    case .offline:
        return String(localized: .refreshErrorOffline)
    case .forbidden:
        return String(localized: .refreshErrorForbidden)
    case .httpError(let code):
        return String(localized: .refreshErrorHttp(String(code)))
    }
}
