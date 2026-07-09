//
//  RefreshErrorMessageTests.swift
//  kolco24Tests
//
//  Зеркало ветвей `refreshErrorMessage` из `ui/common/PullToRefresh.kt`.
//  JVM-теста для него нет — сьют бонусный, покрывает все кейсы `RefreshResult`.
//

import Testing
@testable import kolco24

struct RefreshErrorMessageTests {

    @Test func successBranchesAreSilent() {
        #expect(refreshErrorMessage(.updated) == nil)
        #expect(refreshErrorMessage(.notModified) == nil)
    }

    @Test func skippedIsSilent() {
        // Пропуск cloud-fetch из-за пина гонки на LAN — не ошибка.
        #expect(refreshErrorMessage(.skipped) == nil)
    }

    @Test func offlineMessage() {
        #expect(refreshErrorMessage(.offline) == "Нет сети — не удалось обновить")
    }

    @Test func forbiddenMessage() {
        #expect(refreshErrorMessage(.forbidden) == "Доступ запрещён")
    }

    @Test func httpErrorCarriesCode() {
        #expect(refreshErrorMessage(.httpError(500)) == "Ошибка сервера (500)")
        #expect(refreshErrorMessage(.httpError(418)) == "Ошибка сервера (418)")
    }
}
