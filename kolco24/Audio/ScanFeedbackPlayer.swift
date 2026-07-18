//
//  ScanFeedbackPlayer.swift
//  kolco24
//
//  iOS-адаптер аудио/тактильного фидбека скана — прод-реализация шва
//  `ScanFeedbackPlaying` (`Core/Scan/ChipScanning.swift`), заменяющая no-op
//  `SilentFeedback` в `AppEnvironment.makeShared()`. Порт `data/ScanFeedbackPlayer.kt`:
//  тот же набор исходов (success/failure/neutral + fanfare), тот же выбор клипов.
//
//  Платформенная граница: единственное место в проекте, где `import AVFoundation`
//  и `import UIKit` (хаптики) — grep-инвариант этапа 5 держит их только под `Audio/`.
//  Не тестируется по конвенции (аудио-адаптер, как локейшн-движки / NfcA-адаптеры);
//  звук проверяется на слух на устройстве (Post-Completion).
//
//  Best-effort по контракту протокола: любой сбой воспроизведения проглатывается,
//  скан-флоу никогда не роняется. Во время активной системной NFC-шторки система
//  может глушить хаптики — звук главный канал, поэтому и `.duckOthers` (писк
//  пробивается сквозь музыку в наушниках).
//
//  Дак — только на время клипа: сессия активируется перед воспроизведением и
//  деактивируется (`.notifyOthersOnDeactivation` — система возвращает громкость
//  чужому аудио) по окончании клипа с небольшим хвостом. `prepareToPlay` в init
//  недопустим — он неявно активирует сессию, и подкаст/музыка пользователя
//  приглушались бы с самого старта приложения навсегда.
//
//  Маппинг Kotlin → iOS:
//  - Android SoundPool → по одному предзагруженному `AVAudioPlayer` на клип.
//  - Android VibrationEffect паттерны → хаптик-генераторы UIKit (точные ms-паттерны
//    недоступны публичным API): success 40 мс пульс → light impact; failure двойной
//    буз → notification `.error`; neutral одиночный короткий буз → light impact
//    (без звука, как в Kotlin).
//

import AVFoundation
import os
import UIKit

/// Проигрыватель аудио/тактильного фидбека скана.
///
/// Файлы клипов декодируются в `init` (`AVAudioPlayer(contentsOf:)`), но без
/// `prepareToPlay` — он неявно активировал бы `AVAudioSession` и включил дакинг
/// на старте приложения; буферы готовятся при первом `play()` (десятки мс,
/// для скана незаметно). `AVAudioSession` конфигурируется один раз как `.playback`
/// c `.mixWithOthers`/`.duckOthers`; активируется перед клипом и деактивируется
/// по его окончании (см. `playClip`/`deactivateIfIdle`). Вызовы `play`/`fanfare` —
/// с любого потока: работа с сессией и отложенной деактивацией сериализуется
/// на собственной очереди `sessionQueue`.
final class ScanFeedbackPlayer: ScanFeedbackPlaying {

    /// Хвост после конца клипа до деактивации сессии — покрывает связку
    /// «success-писк → фанфары через 275 мс» (новый клип отменяет и переносит
    /// деактивацию) и неточность `duration`.
    private static let deactivationTailSeconds: TimeInterval = 0.3

    private let successPlayer: AVAudioPlayer?
    private let failurePlayer: AVAudioPlayer?
    private let fanfarePlayer: AVAudioPlayer?
    /// Два экземпляра одного клипа выстрела хлопушки: залпы идут с перекрытием
    /// (правый стартует через `confettiSecondPopDelay`, клип ~0.6 с), а один
    /// `AVAudioPlayer` не умеет играть поверх самого себя — повторный `play()`
    /// перемотал бы первый выстрел на ноль.
    private let fireworksPlayers: [AVAudioPlayer?]

    /// Задержка второго выстрела — синхронно со стаггером правой хлопушки в
    /// `ConfettiPiece.random` (`ConfettiOverlay.swift`, 0.12 с).
    private static let confettiSecondPopDelay: TimeInterval = 0.12

    /// Диагностика best-effort плеера: контракт «сбой проглатывается» остаётся, но причина тишины
    /// (клип не в бандле / не декодировался) видна в Console.app без дебаггера.
    private static let log = Logger(subsystem: "kolco24", category: "Audio")

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    /// Серийная очередь всей работы с `AVAudioSession` и `pendingDeactivation`.
    private let sessionQueue = DispatchQueue(label: "kolco24.audio.session")
    /// Отложенная деактивация сессии; доступ только с `sessionQueue`.
    private var pendingDeactivation: DispatchWorkItem?

    init() {
        // `.playback` + микс/дак: писк слышен поверх музыки, музыка приглушается
        // на время клипа. Сама setCategory сессию не активирует — дак начнётся
        // только с setActive(true) в playClip.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])

        successPlayer = Self.makePlayer("beep_ok3")
        failurePlayer = Self.makePlayer("beep_err")
        fanfarePlayer = Self.makePlayer("checkpoint_mark_completed")
        fireworksPlayers = [
            Self.makePlayer("frequent-ringing-fireworks"),
            Self.makePlayer("frequent-ringing-fireworks"),
        ]
    }

    /// Диспетч по исходу тапа (`feedbackFor` → этот `kind`): success/failure/neutral.
    func play(_ kind: ScanFeedbackKind) {
        switch kind {
        case .success:
            playClip(successPlayer)
            impact.impactOccurred()          // 40-мс пульс Kotlin → лёгкий импакт
        case .failure:
            playClip(failurePlayer)
            notification.notificationOccurred(.error)  // двойной буз Kotlin → error-хаптик
        case .neutral:
            impact.impactOccurred()          // одиночный короткий буз, без звука
        }
    }

    /// Фанфары завершения взятия (все участники собраны) — только звук
    /// (`checkpoint_mark_completed`), как `checkpointCompleteFanfare()` в Kotlin.
    /// Завершающий скан уже проиграл свой обычный success перед этим.
    func fanfare() {
        playClip(fanfarePlayer)
    }

    /// Звук залпа хлопушек: два выстрела (по одному на каждую), второй — через
    /// `confettiSecondPopDelay`, синхронно с визуальным стаггером правой хлопушки.
    /// `playClip` внутри сам уходит на `sessionQueue` (async, не sync — дедлока нет)
    /// и переносит отложенную деактивацию сессии, так что пара выстрелов не дёргает дак.
    func confettiLaunch() {
        Self.log.debug("залп хлопушек: плееры \(self.fireworksPlayers.compactMap { $0 }.count)/2")
        playClip(fireworksPlayers[0])
        sessionQueue.asyncAfter(deadline: .now() + Self.confettiSecondPopDelay) { [weak self] in
            guard let self else { return }
            self.playClip(self.fireworksPlayers[1])
        }
    }

    private func playClip(_ player: AVAudioPlayer?) {
        guard let player else { return }
        sessionQueue.async { [self] in
            // Новый клип отменяет запланированную деактивацию — сессия не дёргается
            // между success-писком и фанфарами.
            pendingDeactivation?.cancel()
            pendingDeactivation = nil

            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            player.currentTime = 0
            player.play()

            let item = DispatchWorkItem { [self] in deactivateIfIdle() }
            pendingDeactivation = item
            sessionQueue.asyncAfter(
                deadline: .now() + player.duration + Self.deactivationTailSeconds,
                execute: item
            )
        }
    }

    /// Деактивация сессии по окончании клипа (только с `sessionQueue`).
    /// `.notifyOthersOnDeactivation` — система возвращает громкость приглушённому
    /// чужому аудио (подкаст/музыка). Защитная проверка: `setActive(false)` при
    /// играющем плеере вернула бы ошибку — тогда просто оставляем сессию активной
    /// до следующего писка.
    private func deactivateIfIdle() {
        pendingDeactivation = nil
        let players = ([successPlayer, failurePlayer, fanfarePlayer] + fireworksPlayers).compactMap { $0 }
        guard !players.contains(where: { $0.isPlaying }) else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func makePlayer(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            log.warning("клип \(name).wav не найден в бандле — звук молчит")
            return nil
        }
        // Без prepareToPlay: он неявно активирует аудиосессию (дак на старте).
        // Файл уже декодирован конструктором; play() подготовит буферы сам.
        do {
            return try AVAudioPlayer(contentsOf: url)
        } catch {
            log.warning("клип \(name).wav не декодировался: \(error) — звук молчит")
            return nil
        }
    }
}
