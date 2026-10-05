//
//  EnglishLocalization.swift
//  kolco24Tests
//
//  Тесты идут в ru (язык Test action в shared-схеме), поэтому английское
//  значение ключа берём явно: `locale` у `LocalizedStringResource` выбирает
//  язык поиска в каталоге, включая плюральные формы.
//

import Foundation

func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

func ru(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "ru")
    return String(localized: resource)
}
