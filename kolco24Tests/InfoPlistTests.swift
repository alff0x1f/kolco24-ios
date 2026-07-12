//
//  InfoPlistTests.swift
//  kolco24Tests
//
//  Смоук-тесты слитого Info.plist (частичный kolco24/Info.plist + генерируемые
//  ключи, GENERATE_INFOPLIST_FILE = YES). Тесты хостятся в приложении, поэтому
//  Bundle.main — это бандл приложения с итоговым plist.
//

import Foundation
import Testing

struct InfoPlistTests {

    @Test func atsAllowsLocalNetworking() throws {
        let ats = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        )
        let allowsLocalNetworking = try #require(ats["NSAllowsLocalNetworking"] as? Bool)
        #expect(allowsLocalNetworking)
    }

    @Test func localNetworkUsageDescriptionIsPresent() throws {
        // Обязателен для доступа к локальной сети (TN3179): без purpose string
        // системный промпт при первом трафике к LAN-серверу гонки (этап 3)
        // остаётся без объяснения для пользователя.
        let usage = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        )
        #expect(!usage.isEmpty)
    }

    @Test func backgroundLocationModeIsDeclared() throws {
        // UIBackgroundModes = [location] приходит из частичного kolco24/Info.plist
        // (Xcode не поддерживает INFOPLIST_KEY_ для этого массива-ключа). Без него
        // фоновая запись GPS-трека (этап 8) молча обрывается при уходе в фон.
        let modes = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        #expect(modes.contains("location"))
    }

    @Test func exportComplianceKeyIsDeclared() throws {
        // ITSAppUsesNonExemptEncryption = false приходит из частичного
        // kolco24/Info.plist (приложение ходит только по HTTPS — экспортный
        // экземпт). Без ключа App Store Connect задаёт вопрос экспорт-комплаенса
        // на каждой загрузке билда.
        let usesNonExempt = try #require(
            Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool
        )
        #expect(usesNonExempt == false)
    }

    @Test func privacyManifestIsBundled() throws {
        // PrivacyInfo.xcprivacy должен доехать в бандл как ресурс: synchronized
        // group подхватывает его автоматически (в отличие от Info.plist, который
        // исключён membershipException'ом). Без манифеста App Store отклоняет
        // загрузку (required-reason API: UserDefaults + SystemBootTime).
        let url = try #require(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let plist = try #require(
            NSDictionary(contentsOf: url) as? [String: Any]
        )
        let apiTypes = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let categories = apiTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        #expect(categories.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        #expect(categories.contains("NSPrivacyAccessedAPICategorySystemBootTime"))

        // Precise location уходит с устройства (GPS-трек + координата взятия), привязана к команде —
        // Apple считает это «collected». Манифест обязан заявить тип, иначе App Store отклоняет билд
        // за расхождение с App-Privacy-опросником (см. docs/release.md §5).
        let collected = try #require(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let location = try #require(
            collected.first { ($0["NSPrivacyCollectedDataType"] as? String) == "NSPrivacyCollectedDataTypePreciseLocation" }
        )
        #expect(location["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
        #expect(location["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        let purposes = try #require(location["NSPrivacyCollectedDataTypePurposes"] as? [String])
        #expect(purposes.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"))

        // Фото-отметки (JPEG-кадры) тоже уходят на сервер — тип должен быть заявлен,
        // иначе App-Privacy-опросник расходится с манифестом.
        let photos = try #require(
            collected.first { ($0["NSPrivacyCollectedDataType"] as? String) == "NSPrivacyCollectedDataTypePhotosorVideos" }
        )
        #expect(photos["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
        #expect(photos["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        let photoPurposes = try #require(photos["NSPrivacyCollectedDataTypePurposes"] as? [String])
        #expect(photoPurposes.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"))
    }

    @Test func generatedKeysSurviveMergeWithPartialPlist() throws {
        // NFCReaderUsageDescription приходит из генерируемой части plist;
        // регресс слияния (например, GENERATE_INFOPLIST_FILE = NO) молча
        // сломал бы NFC-сканирование.
        let nfcUsage = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NFCReaderUsageDescription") as? String
        )
        #expect(!nfcUsage.isEmpty)
    }
}
