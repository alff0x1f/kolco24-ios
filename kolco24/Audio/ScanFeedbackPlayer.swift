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
//  Маппинг Kotlin → iOS:
//  - Android SoundPool → по одному предзагруженному `AVAudioPlayer` на клип.
//  - Android VibrationEffect паттерны → хаптик-генераторы UIKit (точные ms-паттерны
//    недоступны публичным API): success 40 мс пульс → light impact; failure двойной
//    буз → notification `.error`; neutral одиночный короткий буз → light impact
//    (без звука, как в Kotlin).
//

import AVFoundation
import UIKit

/// Проигрыватель аудио/тактильного фидбека скана.
///
/// Плееры предзагружаются в `init` (декод в память + `prepareToPlay`), чтобы первый
/// тап не ждал загрузки; `AVAudioSession` конфигурируется один раз как `.playback`
/// c `.mixWithOthers`/`.duckOthers`. Вызовы `play`/`fanfare` — с любого потока
/// (`AVAudioPlayer.play` и хаптик-генераторы потокобезопасны через диспетч на main
/// для генераторов).
final class ScanFeedbackPlayer: ScanFeedbackPlaying {

    private let successPlayer: AVAudioPlayer?
    private let failurePlayer: AVAudioPlayer?
    private let fanfarePlayer: AVAudioPlayer?

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    init() {
        // `.playback` + микс/дак: писк слышен поверх музыки, музыка приглушается на время клипа.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])

        successPlayer = Self.makePlayer("beep_ok3")
        failurePlayer = Self.makePlayer("beep_err")
        fanfarePlayer = Self.makePlayer("checkpoint_mark_completed")
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

    private func playClip(_ player: AVAudioPlayer?) {
        guard let player else { return }
        // Активируем сессию лениво (первый звук) — быстрее старт приложения, дешевле дак.
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        player.currentTime = 0
        player.play()
    }

    private static func makePlayer(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        return player
    }
}
