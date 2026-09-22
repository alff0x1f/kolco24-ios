//
//  MemberProvisioningLogicTests.swift
//  kolco24Tests
//
//  `Core/Admin/MemberProvisioningLogic`: маппер строк `memberProvisionErrorMessage` по каждой
//  ветке (свои 409/404 + делегирование `provisionErrorMessage`) и `parseMemberNumber`.
//

import Foundation
import Testing
@testable import kolco24

struct MemberProvisioningLogicTests {

    typealias R = PostResult<MemberTagBindResponse>

    // MARK: - memberProvisionErrorMessage

    @Test func errorMessage_conflict_isOtherParticipant() {
        #expect(memberProvisionErrorMessage(R.conflict) == "Браслет уже привязан к другому участнику")
    }

    @Test func errorMessage_notFound_isNotFoundOnServer() {
        #expect(memberProvisionErrorMessage(R.error(code: 404)) == "Не найдено на сервере")
    }

    @Test func errorMessage_otherStatuses_delegateToProvision() {
        #expect(memberProvisionErrorMessage(R.forbidden)
            == "Нет прав администратора этой гонки или ошибка подписи/часов")
        #expect(memberProvisionErrorMessage(R.unauthorized) == "Сессия истекла, войдите снова")
        #expect(memberProvisionErrorMessage(R.badRequest) == "Неверный запрос")
        #expect(memberProvisionErrorMessage(R.rateLimited) == "Слишком часто, подождите немного")
        #expect(memberProvisionErrorMessage(R.offline) == "Нет сети, попробуйте снова")
        #expect(memberProvisionErrorMessage(R.error(code: 500)) == "Ошибка сервера")
        #expect(memberProvisionErrorMessage(R.error(code: nil)) == "Ошибка сервера")
    }

    @Test func errorMessage_unexpectedSuccess_isServerErrorFallback() {
        let resp = MemberTagBindResponse(number: 1, nfcUid: "04AA", code: "00")
        #expect(memberProvisionErrorMessage(R.success(resp)) == "Ошибка сервера")
    }

    // MARK: - parseMemberNumber

    @Test func parseMemberNumber_valid() {
        #expect(parseMemberNumber("101") == 101)
        #expect(parseMemberNumber("1") == 1)
        #expect(parseMemberNumber("007") == 7)
        #expect(parseMemberNumber(" 42 ") == 42)
    }

    @Test func parseMemberNumber_emptyOrZero_isNil() {
        #expect(parseMemberNumber("") == nil)
        #expect(parseMemberNumber("   ") == nil)
        #expect(parseMemberNumber("0") == nil)
        #expect(parseMemberNumber("000") == nil)
    }

    @Test func parseMemberNumber_nonNumeric_isNil() {
        #expect(parseMemberNumber("abc") == nil)
        #expect(parseMemberNumber("12a") == nil)
        #expect(parseMemberNumber("-5") == nil)
        #expect(parseMemberNumber("+5") == nil)
        #expect(parseMemberNumber("1 2") == nil)
        #expect(parseMemberNumber("١٢") == nil)  // не-ASCII цифры
    }

    @Test func parseMemberNumber_overflow_isNil() {
        #expect(parseMemberNumber("99999999999999999999999") == nil)
    }
}
