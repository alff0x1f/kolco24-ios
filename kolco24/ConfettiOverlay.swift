//
//  ConfettiOverlay.swift
//  kolco24
//
//  Празднование взятия КП (этап 11) — два «хлопушечных» залпа из нижних углов поверх «Отметок» после
//  закрытия скан-шита (переосмысление порта `ScanScreen.kt:400–483`: вместо равномерного дождя сверху —
//  баллистический выстрел с боков: быстрый вылет к центру с затуханием скорости, затем медленное
//  порхание вниз с кувырканием). `TimelineView(.animation)` + `Canvas` (подход штриховки
//  `DarkHeroBackground`), каждый кадр — чистая функция от прошедшего времени. Библиотек нет,
//  unit-тестов нет (визуальный код — конвенция всех этапов, как и прочие `Canvas`-рисунки).
//
//  110 частиц (по 55 на сторону) генерируются ОДИН раз на запуск (`@State`, пересоздание по ребру
//  `running` либо при первом монтаже уже с `running == true`): одно завершение взятия живёт в одном
//  коротком показе. `MarksView` гейтит показ (и не запускает при Reduce Motion — фанфара уже отыграла
//  из `ScanModel`).
//

import os
import SwiftUI

// MARK: - ConfettiOverlay

struct ConfettiOverlay: View {
    /// Пока `true` — частицы падают через весь оверлей; ребро `false → true` пересоздаёт частицы и
    /// перезапускает анимацию (фиксируем момент старта в `startedAt`).
    let running: Bool
    /// Событие «дождь дорисован» (прогресс дошёл до 1 по СОБСТВЕННЫМ render-time часам оверлея).
    /// Хост гасит `running` по нему, а не по wall-clock таймеру от запуска: при позднем первом кадре
    /// (системная NFC-шторка ещё уезжает) wall-clock таймер срезал бы хвост дождя.
    var onFinished: () -> Void = {}

    @State private var pieces: [ConfettiPiece] = []
    /// Момент старта текущего запуска — стамп ПЕРВОГО видимого кадра из `timeline.date` (render-time,
    /// не wall-clock; см. body). Прогресс = (now − start)/duration.
    @State private var startedAt: Date?
    /// `onFinished` уже отправлен для текущего запуска (дедуп: кадры с `progress == 1` продолжают идти).
    @State private var finished = false

    /// Диагностика рендера празднования (одна подсистема с хэнд-оффом в `MarksView`).
    private static let log = Logger(subsystem: "kolco24", category: "Celebration")

    /// 3.2 с (исходно 2.8 — `CONFETTI_DURATION_MS`): продлено, чтобы частицы успевали долететь до
    /// нижнего края и уйти за него, а не гаснуть в середине экрана. Единственный источник длительности:
    /// `MarksView` (автосброс) и превью читают отсюда.
    static let durationSec: Double = 3.2

    var body: some View {
        // При `running == false` не рисуем вовсе (нулевая стоимость, как ранний `return` в Kotlin).
        TimelineView(.animation(paused: !running)) { timeline in
            Canvas { ctx, size in
                guard running else { return }
                // Старт отсчёта берём из ПЕРВОГО реально отрисованного кадра (`timeline.date`), а не из
                // wall-clock времени триггера. `TimelineView(.animation)` не тикает, пока приложение не
                // рендерит (экран накрыт системной NFC-шторкой / сцена неактивна) — с wall-clock стартом
                // все 2.8 с «прогорали» за шторкой, и к моменту показа дождь уже кончался. С render-time
                // стартом отсчёт заводится ровно тогда, когда оверлей виден. Мутируем `@State` не в апдейте
                // вью, а отложенно на MainActor (как лог первого кадра).
                guard let startedAt else {
                    Task { @MainActor in
                        guard self.startedAt == nil else { return }
                        self.startedAt = timeline.date
                        Self.log.debug("конфетти: первый видимый кадр, частиц=\(pieces.count)")
                    }
                    return
                }
                let progress = min(1, max(0, timeline.date.timeIntervalSince(startedAt) / Self.durationSec))
                if progress >= 1 {
                    // Дождь дорисован — сигналим хосту (отложенно на MainActor, как стамп старта;
                    // `finished` дедупит: кадры с прогрессом 1 продолжают приходить, событие одно).
                    if !finished {
                        Task { @MainActor in
                            guard !self.finished else { return }
                            self.finished = true
                            Self.log.debug("конфетти: дождь дорисован")
                            onFinished()
                        }
                    }
                    return
                }
                draw(&ctx, size: size, progress: CGFloat(progress))
            }
        }
        .onChange(of: running, initial: true) { _, isRunning in
            if isRunning {
                // Свежая партия + `startedAt = nil` (отсчёт заведёт первый видимый кадр). `initial: true`
                // принципиален: SwiftUI может впервые смонтировать оверлей уже с `running == true`; обычный
                // onChange тогда не стреляет и первый праздник остаётся с пустым массивом частиц.
                pieces = (0..<Self.pieceCount).map { i in ConfettiPiece.random(fromLeft: i % 2 == 0) }
                startedAt = nil
                finished = false
                Self.log.debug("конфетти: запуск, частиц=\(Self.pieceCount)")
            } else {
                startedAt = nil
            }
        }
    }

    /// Один кадр: для каждой частицы — баллистика хлопушки в замкнутой форме (никакого пошагового
    /// состояния — позиция считается напрямую от локального времени `tl`, кадры независимы):
    ///   • вылет из нижнего угла к центру со скоростью, экспоненциально затухающей за `launchTau`
    ///     (путь = v·τ·(1 − e^(−t/τ)) — асимптота, «выстрелил и завис»);
    ///   • падение — плавный разгон до терминальной скорости порхания `fallSpeed` (та же форма с `fallTau`);
    ///   • лёгкий синусоидальный снос, вплывающий после фазы вылета (падение почти прямолинейное,
    ///     «шарики», не порхающие бумажки);
    ///   • мягкое кувыркание: поворот + слабая пульсация короткой стороны прямоугольника (3D-фикция);
    ///   • фейд только на последних 12% жизни — подавляющее большинство частиц к этому моменту уже
    ///     за нижним краем (страховка для одиночных отстающих, чтобы не «застывали» при `progress == 1`).
    private func draw(_ ctx: inout GraphicsContext, size: CGSize, progress p: CGFloat) {
        let t = p * Self.durationSec
        let w = size.width
        let h = size.height
        for piece in pieces {
            let tl = t - piece.delay
            guard tl > 0, tl < piece.life else { continue }

            // Вылет: затухающая скорость (в долях высоты/с — общий масштаб для x и y, чтобы траектория
            // не зависела от соотношения сторон экрана).
            let launch = piece.launchTau * (1 - exp(-tl / piece.launchTau))
            let dirX: CGFloat = piece.fromLeft ? 1 : -1
            let x0 = piece.fromLeft ? -0.04 * w : 1.04 * w
            // Снос вплывает к ~0.9 с — залп летит прямо, порхание начинается на спуске.
            let swayRamp = min(1, tl / 0.9)
            let sway = sin(tl * piece.swayFreq * 2 * .pi + piece.swayPhase) * piece.swayAmp * w * swayRamp
            let x = x0 + dirX * cos(piece.launchAngle) * piece.speed * h * launch + sway

            // Спуск: разгон до терминальной скорости порхания (путь = vT·(t − τ·(1 − e^(−t/τ)))).
            let fall = piece.fallSpeed * h * (tl - piece.fallTau * (1 - exp(-tl / piece.fallTau)))
            let y = piece.y0Frac * h - sin(piece.launchAngle) * piece.speed * h * launch + fall

            // Частица, ушедшая за нижний край, не рисуется (с запасом на размер) — фейд ей не нужен.
            if y > h + 20 { continue }
            let lifeFraction = tl / piece.life
            let alpha = lifeFraction > 0.88 ? 1 - (lifeFraction - 0.88) / 0.12 : 1
            let sPx = piece.sizePt
            let angle = piece.startAngle + piece.spin * tl
            let color = piece.color.opacity(Double(alpha))

            var layer = ctx
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .degrees(Double(angle)))
            if piece.circle {
                let r = sPx / 2
                layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: sPx, height: sPx)), with: .color(color))
            } else {
                // Мягкое кувыркание: короткая сторона слегка пульсирует |sin| (полное схлопывание в
                // ребро выглядело «бумажно» — оставлен лишь намёк на объём).
                let flip = 0.55 + 0.45 * abs(sin(tl * piece.flipFreq * 2 * .pi + piece.flipPhase))
                let short = sPx * 0.7 * flip
                let rect = CGRect(x: -sPx / 2, y: -short / 2, width: sPx, height: short)
                layer.fill(Path(rect), with: .color(color))
            }
        }
    }

    /// Две хлопушки по 55 частиц (был `CONFETTI_PIECE_COUNT = 90` дождя; залпам нужна чуть большая
    /// плотность, чтобы веер читался).
    private static let pieceCount = 110
}

// MARK: - ConfettiPiece

/// Одна частица залпа хлопушки. Все поля рандомизируются один раз при запуске; скорости — в долях
/// высоты экрана в секунду (общий масштаб x/y, траектория не зависит от соотношения сторон).
private struct ConfettiPiece {
    let fromLeft: Bool         // из какого нижнего угла выстрел
    let y0Frac: CGFloat        // высота дула, доля высоты экрана
    let launchAngle: CGFloat   // угол вылета над горизонтом, радианы (к центру экрана)
    let speed: CGFloat         // начальная скорость, высот/с
    let launchTau: CGFloat     // постоянная затухания скорости вылета, с
    let fallSpeed: CGFloat     // терминальная скорость порхания вниз, высот/с
    let fallTau: CGFloat       // постоянная разгона падения, с
    let color: Color
    let sizePt: CGFloat        // длинная сторона, pt
    let spin: CGFloat          // скорость вращения, град/с (со знаком)
    let startAngle: CGFloat    // начальный поворот, градусы
    let swayAmp: CGFloat       // амплитуда сноса-синусоиды, доля ширины
    let swayFreq: CGFloat      // частота сноса, Гц
    let swayPhase: CGFloat     // фаза сноса, радианы
    let flipFreq: CGFloat      // частота кувыркания (пульсация короткой стороны), Гц
    let flipPhase: CGFloat     // фаза кувыркания, радианы
    let delay: CGFloat         // стагер вылета, с (правый залп чуть позже левого)
    let life: CGFloat          // время жизни, с (delay + life <= durationSec)
    let circle: Bool           // круг vs прямоугольник-бумажка

    /// Палитра `ConfettiColors` (`E53935`/`1E88E5`/`F4B400`/`8E44AD`/`1F7A3D` Tertiary/`C65A2E` OrangeCta).
    static let colors: [Color] = [
        Color(hex: "E53935"),
        Color(hex: "1E88E5"),
        Color(hex: "F4B400"),
        Color(hex: "8E44AD"),
        Color(hex: "1F7A3D"),
        Color(hex: "C65A2E"),
    ]

    static func random(fromLeft: Bool) -> ConfettiPiece {
        // Правая хлопушка стреляет на ~0.12 с позже левой («хлоп-хлоп», а не один сплошной залп);
        // джиттер размазывает веер каждой. Стагер мал: хлопушка — вспышка, не струя.
        let delay = (fromLeft ? 0 : 0.12) + CGFloat.random(in: 0..<0.22)
        let y0Frac = CGFloat.random(in: 0.68..<0.88)
        let launchAngle = CGFloat.random(in: (50 * .pi / 180)..<(80 * .pi / 180))
        let speed = CGFloat.random(in: 1.1..<1.9)
        let launchTau = CGFloat.random(in: 0.45..<0.7)
        let life = CGFloat(ConfettiOverlay.durationSec) - delay
        // Скорость падения — на частицу от её собственной высоты взлёта: базовая случайная (спокойный,
        // почти прямой спуск), но не меньше требуемой, чтобы с пика траектории уйти за нижний край ДО
        // начала фейда (последние 12% жизни). Так вылет остаётся энергичным, а гарантия «не гаснут в
        // середине экрана» держится без утяжеления всех частиц разом.
        let rise = sin(launchAngle) * speed * launchTau      // асимптота взлёта, в долях высоты
        let peakY = y0Frac - rise                            // высшая точка (может быть выше экрана, < 0)
        let fadeStart = 0.88 * life
        let requiredFall = (1.05 - peakY) / max(0.1, fadeStart - 0.55)
        return ConfettiPiece(
            fromLeft: fromLeft,
            y0Frac: y0Frac,
            launchAngle: launchAngle,
            speed: speed,
            launchTau: launchTau,
            fallSpeed: max(CGFloat.random(in: 0.45..<0.7), requiredFall),
            fallTau: 0.55,
            color: colors[Int.random(in: 0..<colors.count)],
            sizePt: 7 + CGFloat.random(in: 0..<1) * 7,
            spin: CGFloat.random(in: 90..<300) * (Bool.random() ? 1 : -1),
            startAngle: CGFloat.random(in: 0..<360),
            swayAmp: CGFloat.random(in: 0.003..<0.010),
            swayFreq: CGFloat.random(in: 1.0..<2.0),
            swayPhase: CGFloat.random(in: 0..<(2 * .pi)),
            flipFreq: CGFloat.random(in: 0.5..<1.2),
            flipPhase: CGFloat.random(in: 0..<(2 * .pi)),
            delay: delay,
            // Живёт до конца показа — страховочный фейд последних 12% гасит отстающих раньше, чем они
            // «застыли» бы на экране при `progress == 1`.
            life: life,
            circle: CGFloat.random(in: 0..<1) < 0.4
        )
    }
}

// MARK: - Preview
#if DEBUG
private struct ConfettiPreviewHost: View {
    @State private var running = false
    /// Прод-плеер прямо в превью (один модуль, import не нужен): кнопка воспроизводит и звук
    /// залпа — в реальном флоу его зовёт `MarksView.launchConfetti` через `AppModel`.
    private let feedback = ScanFeedbackPlayer()
    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            Button("Запустить конфетти") {
                running = true
                feedback.confettiLaunch()
            }
                .font(.system(size: 16, weight: .semibold))
            ConfettiOverlay(running: running, onFinished: { running = false })
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    ConfettiPreviewHost()
}
#endif
