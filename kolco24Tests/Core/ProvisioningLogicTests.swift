//
//  ProvisioningLogicTests.swift
//  kolco24Tests
//
//  Зеркало `ui/admin/ProvisioningModelTest.kt` → `Core/Admin/ProvisioningLogic` (этап 10). Имена
//  кейсов 1:1: `provisionErrorMessage` по каждому статусу (строки байт-в-байт из Kotlin),
//  `chipTokenLabel` (хвост / короткий / 5-символьный). `railTicks` **не портируется** — пейджер +
//  rail-тики заменены списком/степпером КП, соответствующие Kotlin-кейсы (`railTicks_*`) сняты.
//

import Foundation
import Testing
@testable import kolco24

struct ProvisioningLogicTests {

    // MARK: - provisionErrorMessage

    @Test func provisionErrorMessage_conflict_isGeneric() {
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.conflict)
            == "Этот тег уже привязан к другому КП")
    }

    @Test func provisionErrorMessage_forbidden_combinesAdminAndSigning() {
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.forbidden)
            == "Нет прав администратора этой гонки или ошибка подписи/часов")
    }

    @Test func provisionErrorMessage_notFound_isCheckpointMissing() {
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.error(code: 404)) == "КП не найдено")
    }

    @Test func provisionErrorMessage_eachStatus() {
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.unauthorized)
            == "Сессия истекла, войдите снова")
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.badRequest) == "Неверный запрос")
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.rateLimited)
            == "Слишком часто, подождите немного")
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.offline) == "Нет сети, попробуйте снова")
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.error(code: 500)) == "Ошибка сервера")
        #expect(provisionErrorMessage(PostResult<TagBindResponse>.error(code: nil)) == "Ошибка сервера")
    }

    // MARK: - chipTokenLabel

    @Test func chipTokenLabel_returnsUidTail() {
        #expect(chipTokenLabel(uid: "0411223344ABCD") == "ABCD")
    }

    @Test func chipTokenLabel_shortUid_returnedWhole() {
        #expect(chipTokenLabel(uid: "AB") == "AB")
        #expect(chipTokenLabel(uid: "ABCD") == "ABCD")
    }

    @Test func chipTokenLabel_fiveChars_truncatesToLastFour() {
        // length == 5 — первый случай, где suffix(4) отличается от самого uid.
        #expect(chipTokenLabel(uid: "ABCDE") == "BCDE")
    }

    // MARK: - kpProvisionStatusLine (строка системной NFC-шторки)

    @Test func kpProvisionStatusLine_showsSelectedKp() {
        #expect(kpProvisionStatusLine(.waitingForChip, number: 10, hint: nil) == "КП 10 · Приложите чип")
        #expect(kpProvisionStatusLine(.waitingForChip, number: nil, hint: nil) == "Приложите чип КП")
        #expect(kpProvisionStatusLine(.binding(uid: "U1"), number: 3, hint: nil) == "Привязка на сервере…")
        #expect(kpProvisionStatusLine(.waitingForWrite(uid: "U1", code: "AB"), number: 3, hint: nil)
            == "КП 03 · Приложите чип ещё раз")
        #expect(kpProvisionStatusLine(.waitingForWrite(uid: "U1", code: "AB"), number: 3, hint: "Приложите тот же чип")
            == "КП 03 · Приложите тот же чип")
        #expect(kpProvisionStatusLine(.success(number: 7), number: 7, hint: nil) == "Записано: КП 07")
        #expect(kpProvisionStatusLine(.failed(reason: "Нет сети"), number: 7, hint: nil) == "Ошибка: Нет сети")
    }
}
