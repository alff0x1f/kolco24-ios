//
//  MapUrl.swift
//  kolco24
//
//  Зеркало `data/map/MapUrl.kt`: разрешение `races[].map_url` в абсолютный URL подложки. Сервер отдаёт
//  значение как есть — `https://…` или путь от корня (`/media/maps/<файл>.mbtiles`), который клиент
//  достраивает от базового адреса API того origin'а, что отдал список гонок (в LAN-режиме — LAN-сервер).
//

import Foundation

/// Разрешает `map_url` гонки относительно [baseURL] — base URL API того origin'а, что её отдал.
///
/// - `nil`/пусто → `nil` (карты нет).
/// - Путь от корня (`/media/maps/8.mbtiles`) → этот путь на хосте [baseURL] (схема и порт базы
///   сохраняются, её собственный путь отбрасывается). LAN-база даёт cleartext `http` — его пропускает
///   `NSAllowsLocalNetworking`.
/// - `//host…`, а также путь с `\`, пробельным или управляющим символом → `nil`: парсеры URL считают `\`
///   за `/` и выкидывают tab/newline, так что такое значение увело бы скачивание на чужой хост.
/// - Абсолютный URL — только `https` с хостом (иначе `nil`), возвращается как есть.
func resolveMapUrl(_ mapUrl: String?, baseURL: String) -> String? {
    guard let mapUrl, !mapUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard mapUrl.hasPrefix("/") else {
        guard let url = URL(string: mapUrl), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return mapUrl
    }
    let unsafe = mapUrl.unicodeScalars.contains {
        $0 == "\\" || CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
    }
    if mapUrl.hasPrefix("//") || unsafe { return nil }
    guard let base = URL(string: baseURL), let scheme = base.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          let host = base.host, !host.isEmpty else { return nil }
    return URL(string: mapUrl, relativeTo: base)?.absoluteString
}
