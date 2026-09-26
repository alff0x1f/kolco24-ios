//
//  TrackAutoControl.swift
//  kolco24
//
//  Автоуправление записью трека по взятию КП. iOS-only — Kotlin-источника нет.
//  Тип КП — серверный `CheckpointType` (`start`/`finish`/`test`/`kp`/`hidden`).
//  `test` берут до соревнований — он запись не трогает. `finish` останавливает;
//  любой другой КП запускает (страховка, если на старте запись не пошла).
//

import Foundation

enum TrackAutoAction: Equatable {
    case start
    case stop
}

func trackAutoAction(checkpointType: String) -> TrackAutoAction? {
    switch checkpointType {
    case "test": return nil
    case "finish": return .stop
    default: return .start
    }
}
