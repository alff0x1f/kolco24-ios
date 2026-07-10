//
//  MarksDisplay.swift
//  kolco24
//
//  Чистая Android-free derived-логика вкладки «Отметки». Kotlin-источник:
//  чистые функции `ui/marks/MarksScreen.kt` (`marksToTiles`, `tileFill`/`TileFill`,
//  `hiddenTakenTokens`, `tokensLabel`, лестница empty-состояний `MarksEmpty`,
//  фото-часть: `photoPaths`/`photoCount` на тайле, `lightboxPhotos`,
//  `PhotoReviewSummary`/`photoReviewSummary` — этап 7). Никакого UIKit/SwiftUI.
//
//  Ветки NFC-доступности лестницы empty-состояний (`nfcDisabled`/`nfcAvailable`)
//  опущены осознанно — все поддерживаемые iPhone имеют NFC, роутинг «нет NFC →
//  фото» на iOS неприменим.
//
//  Цвета тайла представлены как ARGB `UInt32` (Kotlin `Color(0xFFRRGGBB)` — value
//  class над Long); маппинг в пиксельный цвет — во вьюхе (этап 7).
//

import Foundation

/// Тип взятия для отображения тайла. Порт `enum class MarkKind`.
enum MarkTileKind {
    case nfc
    case photo
}

/// Один тайл сетки «Отметок» — одно complete-взятие. Порт display-класса
/// Kotlin `Mark`.
struct MarkTile: Equatable {
    /// Номер КП, двузначный с ведущим нулём.
    let number: String
    /// Живая цена КП (через `costOf`).
    let cost: Int
    let kind: MarkTileKind
    /// Компактное время взятия `HH:mm` (тайл сетки).
    let time: String
    /// Полное «дата · время» взятия (только для лайтбокса; поле не
    /// фото-специфично).
    let dateTime: String
    let color: CheckpointColor?
    /// Относительные (`marks/<markId>/<uuid>.jpg`) пути кадров этого взятия;
    /// корень каталога резолвится на месте рендера, никогда здесь. Несётся
    /// **любым** взятием (NFC-взятие тоже может нести фото-доказательство),
    /// так что бейдж «+N» гонится [photoCount] независимо от [kind].
    let photoPaths: [String]

    /// Число кадров взятия — выводится из списка, отдельного поля в БД нет.
    var photoCount: Int { photoPaths.count }

    init(
        number: String,
        cost: Int,
        kind: MarkTileKind,
        time: String,
        dateTime: String = "",
        color: CheckpointColor? = nil,
        photoPaths: [String] = []
    ) {
        self.number = number
        self.cost = cost
        self.kind = kind
        self.time = time
        self.dateTime = dateTime
        self.color = color
        self.photoPaths = photoPaths
    }
}

/// Чистое отображение локальных взятий в тайлы — **один тайл на complete-взятие**
/// (повторное взятие того же КП — отдельный тайл). Только `complete`-взятия: КП,
/// просканированный без полного ростера, остаётся `complete=false` и не тайлится.
/// [marks] приходит newest-first (как отдаёт observation); тайлы возвращаются
/// **oldest-first**, чтобы новое взятие добавлялось в конец сетки. [costOf]
/// резолвит **живую** цену КП (id → текущая цена) с фолбэком на снимок; [colorOf]
/// резолвит цветовой токен КП для заливки тайла. Время тайла — **trusted**
/// (`trustedTakenAt`) при наличии, иначе сырое `takenAt`, так что сброс часов
/// телефона не сдвигает показанное время. Порт `marksToTiles`.
func marksToTiles(
    _ marks: [Mark],
    costOf: (Mark) -> Int = { $0.cost },
    colorOf: (Mark) -> CheckpointColor? = { _ in nil }
) -> [MarkTile] {
    let timeFmt = markTimeFormatter()
    let dateTimeFmt = markDateTimeFormatter()
    return marks.filter { $0.complete }
        .reversed()
        .map { m in
            // Предпочитаем trusted (устойчивое к перекосу часов) время взятия;
            // фолбэк на сырое wall для untrusted/legacy строк.
            let effectiveTakenAt = m.trustedTakenAt ?? m.takenAt
            let date = Date(timeIntervalSince1970: Double(effectiveTakenAt) / 1000.0)
            return MarkTile(
                number: paddedNumber(m.checkpointNumber),
                cost: costOf(m),
                kind: m.method == "photo" ? .photo : .nfc,
                time: timeFmt.string(from: date),
                dateTime: dateTimeFmt.string(from: date),
                color: colorOf(m),
                photoPaths: PhotoPaths.decode(m.photoPath)
            )
        }
}

/// Один кадр глобальной ленты лайтбокса: его относительный путь [path] плюс
/// взятие ([tile]), которому он принадлежит — тайл питает КП-чип этой страницы.
/// Корень каталога резолвится на месте рендера. Порт `LightboxPhoto`.
struct LightboxPhoto: Equatable {
    let path: String
    let tile: MarkTile
}

/// Расплющить кадры всех взятий в одну упорядоченную ленту, чтобы лайтбокс
/// листался по **всем** фото, а не только по кадрам тапнутого взятия. Порядок
/// сетки (oldest-first, как `marksToTiles`), так что свайп следует визуальному
/// порядку тайлов; кадры дают только взятия, реально несущие фото.
/// Порт `lightboxPhotos`.
func lightboxPhotos(_ tiles: [MarkTile]) -> [LightboxPhoto] {
    tiles.flatMap { tile in tile.photoPaths.map { LightboxPhoto(path: $0, tile: tile) } }
}

/// Фото-часть («без чипа») зачёта, ожидающая проверки судьёй: число КП, их
/// баллы и display-токены каждого КП («стоимость-номер», словарь токенов тайла;
/// КП с нулевой ценой — голый zero-padded номер) в порядке сетки (oldest-first).
/// Порт `PhotoReviewSummary`.
struct PhotoReviewSummary: Equatable {
    let count: Int
    let points: Int
    let tokens: [String]
}

/// Чистая сводка **КП**, требующих проверки судьёй — зачтённых (`complete`)
/// только фото-взятиями (`method == "photo"`: чип КП не читался, фото —
/// единственное доказательство). По-КП, зеркаля `distinctBy { checkpointId }`
/// метрик: повторное фото-взятие того же КП считается однажды, а КП, у которого
/// *также* есть complete NFC-взятие, исключается целиком — чип уже доказывает
/// посещение (его баллы идут от NFC-взятия), судьям гейтить нечего. Аналогично
/// NFC-взятие, лишь *доклеившее* фото-доказательство, не считается. Баллы идут
/// через тот же живой [costOf], что и метрики, так что правка цены организатором
/// (или раскрытие легенды — фото-взятие ещё-залоченного КП снимает `cost = 0` и
/// самокорректируется на reveal) отражается. `nil`, когда ни один КП не
/// photo-only — нотис исчезает целиком, а не рендерит нулевое состояние.
/// Порт `photoReviewSummary`.
func photoReviewSummary(
    _ marks: [Mark],
    costOf: (Mark) -> Int = { $0.cost }
) -> PhotoReviewSummary? {
    let complete = marks.filter { $0.complete }
    let chipVerified = Set(complete.filter { $0.method != "photo" }.map { $0.checkpointId })
    // [marks] приходит newest-first; dedupe оставляет новейшее взятие каждого КП,
    // reverse даёт oldest-first — токены следуют порядку тайловой сетки.
    var seen = Set<Int>()
    var photoOnly: [Mark] = []
    for mark in complete
    where mark.method == "photo" && !chipVerified.contains(mark.checkpointId) {
        if seen.insert(mark.checkpointId).inserted {
            photoOnly.append(mark)
        }
    }
    photoOnly.reverse()
    if photoOnly.isEmpty { return nil }
    return PhotoReviewSummary(
        count: photoOnly.count,
        points: photoOnly.reduce(0) { $0 + costOf($1) },
        tokens: photoOnly.map { m in
            let cost = costOf(m)
            let number = paddedNumber(m.checkpointNumber)
            return cost > 0 ? "\(cost)-\(number)" : number
        }
    )
}

/// Чистые токены **взятых-но-всё-ещё-скрытых** КП — `complete`-взятия, чей КП
/// всё ещё locked в легенде ([lockedIds]), поэтому его цена неизвестна клиенту и
/// взятие даёт 0 в СУММУ до раскрытия. По-КП (`distinctBy checkpointId`),
/// oldest-first как сетка. Токен — «?-NN» (`?` там, где стояла бы цифра цены).
/// Пустой список = нет нотиса. Порт `hiddenTakenTokens`.
func hiddenTakenTokens(_ marks: [Mark], lockedIds: Set<Int>) -> [String] {
    // Kotlin: filter → distinctBy(checkpointId) → asReversed. [marks] newest-first, поэтому
    // dedupe оставляет НОВЕЙШЕЕ взятие каждого КП, а reverse даёт порядок по возрастанию
    // времени новейшего взятия (важно лишь при чередующихся повторных взятиях одного КП).
    var seen = Set<Int>()
    var result: [String] = []
    for mark in marks
    where mark.complete && lockedIds.contains(mark.checkpointId) {
        if seen.insert(mark.checkpointId).inserted {
            result.append("?-\(paddedNumber(mark.checkpointNumber))")
        }
    }
    return result.reversed()
}

/// Список токенов нотиса в скобках, обрезанный до [max] — длинная фото-серия не
/// должна раздувать карточку. За порогом хвост сворачивается в многоточие:
/// «1-02, 2-03, 5-04, …». Порт `tokensLabel`.
func tokensLabel(_ tokens: [String], max: Int = 3) -> String {
    if tokens.count <= max {
        return tokens.joined(separator: ", ")
    }
    return tokens.prefix(max).joined(separator: ", ") + ", …"
}

/// Состояние пустого экрана «Отметок» (урезанный порт `MarksEmpty`; NFC-ветки —
/// этап 5). `none` подавляет мигание empty-state до первой эмиссии observation.
enum MarksEmptyState {
    /// Загрузка / нет данных — ничего не показываем.
    case none
    /// Команда не выбрана — CTA выбора команды.
    case chooseTeam
    /// Не все участники с чипом — нудж привязки.
    case bindChips
    /// Готов к отметке.
    case ready
}

/// Лестница пустых состояний. `loading` подавляет мигание; нет команды → выбор
/// команды; не привязаны чипы (`memberCount > 0 && boundCount < memberCount`) →
/// нудж привязки; иначе → готов. Порт ветвления `MarksEmpty` без NFC-веток.
func marksEmptyState(
    loading: Bool,
    hasTeam: Bool,
    memberCount: Int,
    boundCount: Int
) -> MarksEmptyState {
    if loading { return .none }
    if !hasTeam { return .chooseTeam }
    if memberCount > 0 && boundCount < memberCount { return .bindChips }
    return .ready
}

/// Заливка тайла и (нелюминантный, фиксированный) цвет текста, читаемый на ней.
/// ARGB `UInt32`. Порт `data class TileFill`.
struct TileFill: Equatable {
    let fill: UInt32
    let text: UInt32
}

// Приглушённая палитра заливки цветной сетки (screen-scoped — намеренно отлична
// от ярких bar-оттенков легенды). Шесть цветов дисциплины фиксированы в light &
// dark; только нейтраль флипается с темой. Порт значений `MarksScreen.kt`.
private let fillRed: UInt32 = 0xFFCB4233
private let fillOrange: UInt32 = 0xFFC15A2E
private let fillBlue: UInt32 = 0xFF2F6CAE
private let fillGreen: UInt32 = 0xFF2E9E57
private let fillYellow: UInt32 = 0xFFC99A1E
private let fillPurple: UInt32 = 0xFF7C5AC0
private let tileInk: UInt32 = 0xFF161A1F
private let tileWhite: UInt32 = 0xFFFFFFFF
private let neutralFillLight: UInt32 = 0xFFD6DCE4
private let neutralFillDark: UInt32 = 0xFF2A323C
private let neutralTextDark: UInt32 = 0xFFD6DCE4

/// Чистый маппинг цвет КП → (заливка, текст) цветной сетки. Белый текст на
/// red/orange/blue/green/purple, тёмный [tileInk] на yellow; `nil` (нет/неизвестный
/// токен) → тема-зависимая нейтраль. [darkTheme] — plain Bool (без Compose-лукапа
/// внутри), чтобы оставаться юнит-тестируемым. Порт `tileFill`.
func tileFill(_ color: CheckpointColor?, darkTheme: Bool) -> TileFill {
    switch color {
    case .red: return TileFill(fill: fillRed, text: tileWhite)
    case .orange: return TileFill(fill: fillOrange, text: tileWhite)
    case .blue: return TileFill(fill: fillBlue, text: tileWhite)
    case .green: return TileFill(fill: fillGreen, text: tileWhite)
    case .yellow: return TileFill(fill: fillYellow, text: tileInk)
    case .purple: return TileFill(fill: fillPurple, text: tileWhite)
    case nil:
        return darkTheme
            ? TileFill(fill: neutralFillDark, text: neutralTextDark)
            : TileFill(fill: neutralFillLight, text: tileInk)
    }
}

/// Двузначный номер КП с ведущим нулём.
private func paddedNumber(_ number: Int) -> String {
    let s = String(number)
    return s.count >= 2 ? s : String(repeating: "0", count: 2 - s.count) + s
}

/// `HH:mm`, Locale US, локальный часовой пояс — как `SimpleDateFormat` в Kotlin.
private func markTimeFormatter() -> DateFormatter {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "HH:mm"
    return fmt
}

/// `dd.MM.yyyy '·' HH:mm` (средняя точка — литерал). Порт `fmtDateTime`.
private func markDateTimeFormatter() -> DateFormatter {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "dd.MM.yyyy '·' HH:mm"
    return fmt
}
