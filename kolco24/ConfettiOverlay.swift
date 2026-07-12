//
//  ConfettiOverlay.swift
//  kolco24
//
//  Празднование взятия КП (этап 11) — одноразовый дождь вращающихся, сносимых, угасающих частиц поверх
//  «Отметок» после закрытия скан-шита. Порт `ScanScreen.kt:400–483` (`ConfettiOverlay`/`ConfettiPiece`):
//  `TimelineView(.animation)` + `Canvas` (подход штриховки `DarkHeroBackground`), каждый кадр — чистая
//  функция от прошедшего времени. Библиотек нет, unit-тестов нет (визуальный код — конвенция всех этапов,
//  как и прочие `Canvas`-рисунки).
//
//  90 частиц генерируются ОДИН раз на запуск (`@State`, пересоздание по ребру `running`): одно завершение
//  взятия живёт в одном коротком показе — ре-рандомизация на реплей не нужна. `MarksView` гейтит показ
//  `running` (и не запускает при Reduce Motion — фанфара уже отыграла из `ScanModel`).
//

import SwiftUI

// MARK: - ConfettiOverlay

struct ConfettiOverlay: View {
    /// Пока `true` — частицы падают через весь оверлей; ребро `false → true` пересоздаёт частицы и
    /// перезапускает анимацию (фиксируем момент старта в `startedAt`).
    let running: Bool

    @State private var pieces: [ConfettiPiece] = []
    /// Момент старта текущего запуска (в секундах монотонных часов `TimelineView`); прогресс = (now − start)/duration.
    @State private var startedAt: Date?

    /// 2.8 с — `CONFETTI_DURATION_MS`.
    private static let durationSec: Double = 2.8

    var body: some View {
        // При `running == false` не рисуем вовсе (нулевая стоимость, как ранний `return` в Kotlin).
        TimelineView(.animation(paused: !running)) { timeline in
            Canvas { ctx, size in
                guard running, let startedAt else { return }
                let progress = min(1, max(0, timeline.date.timeIntervalSince(startedAt) / Self.durationSec))
                draw(&ctx, size: size, progress: CGFloat(progress))
            }
        }
        .onChange(of: running) { _, isRunning in
            if isRunning {
                // Ребро запуска: свежая партия частиц + сброс отсчёта.
                pieces = (0..<Self.pieceCount).map { _ in ConfettiPiece.random() }
                startedAt = Date()
            } else {
                startedAt = nil
            }
        }
    }

    /// Один кадр: для каждой частицы — своё падение по окну `[delayFraction, delayFraction + fallFraction]`,
    /// снос синусоидой, фейд на последних 20% пути, поворот вокруг центра; прямоугольник 1:0.7 или круг.
    private func draw(_ ctx: inout GraphicsContext, size: CGSize, progress p: CGFloat) {
        let startY = -0.1 * size.height
        let endY = size.height + 0.1 * size.height
        for piece in pieces {
            let local = (p - piece.delayFraction) / piece.fallFraction
            if local <= 0 || local >= 1 { continue }
            let y = startY + (endY - startY) * local
            let sway = sin(local * piece.turns * .pi * 2) * piece.wobble * size.width
            let x = piece.xStart * size.width + piece.drift * size.width * local + sway
            let alpha = local > 0.8 ? 1 - (local - 0.8) / 0.2 : 1
            let sPx = piece.sizePt
            let angle = piece.startAngle + piece.turns * 360 * local
            let color = piece.color.opacity(Double(alpha))

            var layer = ctx
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .degrees(Double(angle)))
            if piece.circle {
                let r = sPx / 2
                layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: sPx, height: sPx)), with: .color(color))
            } else {
                let rect = CGRect(x: -sPx / 2, y: -sPx * 0.35, width: sPx, height: sPx * 0.7)
                layer.fill(Path(rect), with: .color(color))
            }
        }
    }

    /// `CONFETTI_PIECE_COUNT = 90`.
    private static let pieceCount = 90
}

// MARK: - ConfettiPiece

/// Одна частица конфетти. Все поля рандомизируются один раз при запуске (порт `ConfettiPiece`).
private struct ConfettiPiece {
    let xStart: CGFloat        // стартовая колонка, доля ширины
    let color: Color
    let sizePt: CGFloat        // длинная сторона, pt (dp-аналог)
    let turns: CGFloat         // полных оборотов за падение (задаёт и период снос-синусоиды)
    let startAngle: CGFloat    // начальный поворот, градусы
    let drift: CGFloat         // суммарный горизонтальный снос, доля ширины (± вокруг старта)
    let fallFraction: CGFloat  // доля общего прогресса на падение (скорость)
    let delayFraction: CGFloat // стагер перед стартом падения
    let wobble: CGFloat        // амплитуда сноса, доля ширины
    let circle: Bool           // круг vs прямоугольник

    /// Палитра `ConfettiColors` (`E53935`/`1E88E5`/`F4B400`/`8E44AD`/`1F7A3D` Tertiary/`C65A2E` OrangeCta).
    static let colors: [Color] = [
        Color(hex: "E53935"),
        Color(hex: "1E88E5"),
        Color(hex: "F4B400"),
        Color(hex: "8E44AD"),
        Color(hex: "1F7A3D"),
        Color(hex: "C65A2E"),
    ]

    static func random() -> ConfettiPiece {
        let fall = 0.55 + CGFloat.random(in: 0..<1) * 0.35
        return ConfettiPiece(
            xStart: CGFloat.random(in: 0..<1),
            color: colors[Int.random(in: 0..<colors.count)],
            sizePt: 7 + CGFloat.random(in: 0..<1) * 7,
            turns: 1 + CGFloat.random(in: 0..<1) * 3,
            startAngle: CGFloat.random(in: 0..<1) * 360,
            drift: (CGFloat.random(in: 0..<1) - 0.5) * 0.4,
            fallFraction: fall,
            // Стагер ограничен так, что `delay + fall <= 1`: каждая частица успевает упасть (и уйти с экрана)
            // к моменту `progress == 1` — иначе поздняя/медленная зависла бы посреди экрана.
            delayFraction: CGFloat.random(in: 0..<1) * (1 - fall),
            wobble: 0.02 + CGFloat.random(in: 0..<1) * 0.05,
            circle: CGFloat.random(in: 0..<1) < 0.3
        )
    }
}

// MARK: - Preview
#if DEBUG
private struct ConfettiPreviewHost: View {
    @State private var running = false
    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            Button("Запустить конфетти") { running = true }
                .font(.system(size: 16, weight: .semibold))
            ConfettiOverlay(running: running)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .task(id: running) {
            guard running else { return }
            try? await Task.sleep(for: .milliseconds(2800))
            running = false
        }
    }
}

#Preview {
    ConfettiPreviewHost()
}
#endif
