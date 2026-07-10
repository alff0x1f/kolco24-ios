//
//  UploadModels.swift
//  kolco24
//
//  Зеркало `data/track/TrackModels.kt` L79–98 (upload-часть) + `combineOutcome`
//  из `data/MarkRepository.kt` L502. Чистый Foundation, без framework-импортов —
//  чтобы UI-модель статуса выгрузки оставалась JVM-тестируемой.
//

/// Две независимые цели, в которые дренажит выгрузка: LAN-сервер финиша («Финиш»)
/// и облачный HTTPS-сервер («Интернет»).
enum UploadTarget {
    case local
    case cloud
}

/// Терминальный исход одной попытки дренажа цели: чистый слив / нет сети / прочая ошибка.
enum UploadResultKind {
    case ok
    case offline
    case error
}

/// Последний исход дренажа одной цели с меткой стенных часов, когда он записан
/// (для строки «N мин назад»).
struct TargetUploadOutcome: Equatable {
    let kind: UploadResultKind
    let atWallMs: Int64
}

/// Свести исходы metadata-цикла и frame-drain-цикла одного скоупа в единственное
/// значение, репортящееся наверх — детерминированный приоритет
/// **`error` > `offline` > `ok` > `nil`**, зафиксированный так, чтобы сообщение
/// строки статуса не зависело от порядка вызовов: frame `ok` никогда не должен
/// маскировать metadata `error`/`offline`. `nil` только когда **ни один** цикл
/// ничего не пытался (в этот триггер для цели ничего не было в очереди).
///
/// Задел этапа 7 (метаданные + кадры фото); в этапе 6 используется тривиально.
func combineOutcome(_ metadata: UploadResultKind?, _ frame: UploadResultKind?) -> UploadResultKind? {
    let results = [metadata, frame].compactMap { $0 }
    if results.contains(.error) {
        return .error
    }
    if results.contains(.offline) {
        return .offline
    }
    if results.contains(.ok) {
        return .ok
    }
    return nil
}
