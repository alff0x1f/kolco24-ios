//
//  TrackPointMapper.swift
//  kolco24
//
//  Чистый маппер батча сырых фиксов в строки трека. Зеркало
//  `TrackRepository.insertAll` (L70–88) + `RawFix.toTrackPoint` (L109–132)
//  `kolco24_app_v2`, слитых в одну чистую функцию: персист (`trackStore.insertAll`)
//  делает вызывающий (`TrackRecorder`), маппинг остаётся Android-/GRDB-free и
//  тестируется без БД.
//
//  Снимок стенных/монотонных часов и boot-сессии берётся **один на батч**
//  (`wallNow`/`elapsedNow`/`bootCount`), затем каждый фикс получает:
//  - `elapsedAt = elapsedRealtimeNanos / 1_000_000` — монотонный момент фикса (мс);
//  - `trustedMs = trustedMsFor(elapsedAt)` — доверенное время **фикса** (nil без
//    синка), инжектится замыканием (в проде `TrackRecorder` заранее `await`-ит
//    `TrustedClock.trustedAt` в своём async-цикле — actor в sync-замыкание не
//    заворачивается);
//  - `wallMs = wallNow + (elapsedAt − elapsedNow)` — back-projection стенных часов
//    к моменту фикса (честный per-point fallback под батч-вставкой одним wall-мгновением);
//  - `id = idFactory()` — клиентский UUID (идемпотентный merge двух серверов);
//  - `uploadedLocal/Cloud = false` — пер-таргетные семена доставки.
//
//  Время и UUID — параметрами, поэтому маппер детерминирован (идиома `makeKpTakeMark`).
//

import Foundation

/// Смапить батч сырых фиксов [fixes] в строки трека одной чистой функцией. Пустой
/// вход → `[]`. Зеркало `insertAll` + `toTrackPoint`: снимок времени/boot один на
/// батч передаётся аргументами ([wallNow]/[elapsedNow]/[bootCount]), [segmentId] —
/// id сессии записи (один на «Начать запись»), штампуется на каждую строку.
/// [trustedMsFor] вычисляет доверенное время по `elapsedAt` фикса, [idFactory] —
/// клиентский UUID (вызывается по разу на фикс).
func makeTrackPoints(
    fixes: [RawFix],
    raceId: Int,
    teamId: Int,
    segmentId: String,
    wallNow: Int64,
    elapsedNow: Int64,
    bootCount: Int?,
    trustedMsFor: (Int64) -> Int64?,
    idFactory: () -> String
) -> [TrackPoint] {
    fixes.map { fix in
        let elapsedAt = fix.elapsedRealtimeNanos / 1_000_000
        return TrackPoint(
            id: idFactory(),
            raceId: raceId,
            teamId: teamId,
            lat: fix.lat,
            lon: fix.lon,
            accuracy: fix.accuracy,
            altitude: fix.altitude,
            verticalAccuracyMeters: fix.verticalAccuracyMeters,
            gpsTimeMs: fix.gpsTimeMs,
            elapsedRealtimeAt: elapsedAt,
            bootCount: bootCount,
            wallMs: wallNow + (elapsedAt - elapsedNow),
            trustedMs: trustedMsFor(elapsedAt),
            segmentId: segmentId,
            uploadedLocal: false,
            uploadedCloud: false
        )
    }
}
