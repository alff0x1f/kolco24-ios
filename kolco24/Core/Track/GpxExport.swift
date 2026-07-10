//
//  GpxExport.swift
//  kolco24
//
//  Чистая, framework-free GPX-сериализация. Зеркало `data/track/GpxExport.kt` 1:1
//  (JVM-юнит-тестируемо, без Android/UIKit — как `TrackPoints.swift`). Вызывающая
//  сторона передаёт уже отфильтрованные (`filterPoints`) и reboot-safe
//  отсортированные (`sortedTrackPoints`) точки; сериализатор остаётся тупым и
//  тотальным.
//
//  Трек эмитится как GPX 1.1: один `<trk>` с `<name>`, затем **один `<trkseg>` на
//  каждый последовательный ран `TrackPoint.segmentId`**. Корректно упорядоченный
//  вход держит каждую сессию записи непрерывной, поэтому разрыв stop→start
//  рендерится отдельными сегментами, а не «телепорт-линией» (как сервер группирует
//  по `segment_id`). `<time>` точки — `trustedMs ?? wallMs` в ISO-8601 UTC; `<ele>`
//  опускается при `altitude == nil`. Координаты в `%.6f` с точкой независимо от
//  локали устройства.
//

import Foundation

private let GPX_HEADER =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
    "<gpx version=\"1.1\" creator=\"Kolco24\" xmlns=\"http://www.topografix.com/GPX/1/1\">"

/// ISO-8601 UTC форматтер `yyyy-MM-dd'T'HH:mm:ss'Z'` с POSIX-локалью (стабильный вывод).
private let gpxIsoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f
}()

/// Построить GPX-документ для [points] (предполагаются пред-фильтрованными и упорядоченными)
/// под единым именованным треком.
func buildGpx(points: [TrackPoint], trackName: String) -> String {
    var sb = ""
    sb += GPX_HEADER
    sb += "\n"
    sb += "  <trk>\n"
    sb += "    <name>" + xmlEscape(trackName) + "</name>\n"

    // Группировка последовательных ранов в <trkseg> по segmentId; глобальный порядок — за вызывающим.
    var currentSegment: String? = nil
    var segmentOpen = false
    for p in points {
        if !segmentOpen || p.segmentId != currentSegment {
            if segmentOpen { sb += "    </trkseg>\n" }
            sb += "    <trkseg>\n"
            segmentOpen = true
            currentSegment = p.segmentId
        }
        sb += "      <trkpt lat=\"" + num(p.lat) + "\" lon=\"" + num(p.lon) + "\">\n"
        if let altitude = p.altitude {
            sb += "        <ele>" + num(altitude) + "</ele>\n"
        }
        let date = Date(timeIntervalSince1970: Double(trackPointTimeMs(p)) / 1000)
        sb += "        <time>" + gpxIsoFormatter.string(from: date) + "</time>\n"
        sb += "      </trkpt>\n"
    }
    if segmentOpen { sb += "    </trkseg>\n" }

    sb += "  </trk>\n"
    sb += "</gpx>\n"
    return sb
}

/// Безопасное датированное имя GPX-файла, напр. `kolco24-148-2026-06-26.gpx`. [teamLabel] санитизируется.
func gpxFileName(teamLabel: String, dateIso: String) -> String {
    let trimmed = teamLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "track" : trimmed
    let safe = base.replacingOccurrences(
        of: "[^A-Za-z0-9_-]",
        with: "_",
        options: .regularExpression
    )
    return "kolco24-\(safe)-\(dateIso).gpx"
}

/// `%.6f` с точкой-разделителем (POSIX/C-локаль `String(format:)`), независимо от локали устройства.
private func num(_ v: Double) -> String {
    String(format: "%.6f", v)
}

/// XML-эскейп пяти спецсимволов (`& < > " '`).
private func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.append(c)
        }
    }
    return out
}
