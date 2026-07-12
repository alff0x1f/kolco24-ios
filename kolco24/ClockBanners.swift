//
//  ClockBanners.swift
//  kolco24
//
//  Поверхности баннера сдвига часов (этап 11). Порт ПОВЕДЕНИЯ (не структуры) `ui/common/
//  ClockWarningBanner.kt` + судейская NoSync-карточка из `ui/admin/JudgeScanScreen.kt`. Три
//  поверхности, все читают `AppModel.clockStatus` (единственный потребитель `statusUpdates`):
//
//  1. `GlobalClockBanner` — глобальная плашка над вкладками (`.safeAreaInset` в `ContentView`);
//     показывается ТОЛЬКО на `.skewed`, `.noSync`/`.ok` → нулевая высота (паритет с Android).
//  2. `ScanClockBanner` — плашка в скан-оверлее: `.skewed` красная (зеркалит глобальную),
//     `.noSync` — мягкая «Время не подтверждено…» (единственное место NoSync у участника),
//     `.ok` — ничего.
//  3. `JudgeClockBanner` — судейский вариант: `.skewed` — та же красная плашка, `.noSync` —
//     заметная error-карточка (судье доверенное время критично), `.ok` — ничего.
//
//  Тексты байт-в-байт с Android. Цвета — только токены (`brandRed`/`card`/`sub`/`hairline`),
//  `formatSkewMinutes` из `Core/Time/SkewFormat.swift`.
//

import SwiftUI

// MARK: - Тексты (байт-в-байт с Android)

/// «Часы телефона расходятся с сервером на N мин — проверьте дату и время» (`ClockWarningBanner.kt`).
private func skewedText(_ skewMs: Int64) -> String {
    "Часы телефона расходятся с сервером на \(formatSkewMinutes(skewMs)) — проверьте дату и время"
}

/// Мягкая NoSync-строка участника (`ScanClockBanner`, `ClockStatus.NoSync`).
private let softNoSyncText =
    "Время не подтверждено — подключитесь к сети. Отметка всё равно будет сохранена."

/// Заголовок заметной судейской NoSync-карточки (`JudgeScanNoSyncCard`).
private let judgeNoSyncText =
    "Время не подтверждено — синхронизируйте до начала работы"

// MARK: - Глобальный баннер (над вкладками)

/// Глобальная плашка сдвига часов — во всю ширину под таб-баром. Показывается только на `.skewed`
/// (`.noSync`/`.ok` → нулевая высота, как на Android). `brandRed`-контейнер, белый текст.
struct GlobalClockBanner: View {
    let status: ClockStatus

    var body: some View {
        if case let .skewed(skewMs) = status {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(skewedText(skewMs))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.hPad)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.brandRed)
        }
    }
}

// MARK: - Плашка скан-оверлея

/// Плашка сдвига в скан-оверлее: `.skewed` — красная, `.noSync` — мягкая, `.ok` — ничего.
struct ScanClockBanner: View {
    let status: ClockStatus

    var body: some View {
        switch status {
        case let .skewed(skewMs):
            ClockRow(
                icon: "clock.badge.exclamationmark",
                text: skewedText(skewMs),
                container: Color.brandRed,
                content: .white,
                bordered: false
            )
        case .noSync:
            ClockRow(
                icon: "icloud.slash",
                text: softNoSyncText,
                container: Color.card,
                content: Color.sub,
                bordered: true
            )
        case .ok:
            EmptyView()
        }
    }
}

// MARK: - Судейская плашка

/// Судейский вариант: `.skewed` — та же красная плашка, что у участника; `.noSync` — заметная
/// error-карточка (судье доверенное время критично); `.ok` — ничего.
struct JudgeClockBanner: View {
    let status: ClockStatus

    var body: some View {
        switch status {
        case let .skewed(skewMs):
            ClockRow(
                icon: "clock.badge.exclamationmark",
                text: skewedText(skewMs),
                container: Color.brandRed,
                content: .white,
                bordered: false
            )
        case .noSync:
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.brandRed)
                Text(judgeNoSyncText)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.brandRed)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.brandRed.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius)
                    .stroke(Color.brandRed.opacity(0.35), lineWidth: 1)
            )
        case .ok:
            EmptyView()
        }
    }
}

// MARK: - Переиспользуемый ряд

/// Ряд «иконка + текст» в скруглённом контейнере — два стиля (красный / мягкий) через параметры.
private struct ClockRow: View {
    let icon: String
    let text: String
    let container: Color
    let content: Color
    /// Мягкий стиль обводится `hairline` (карточный фон на светлой теме иначе сливается с бумагой).
    let bordered: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(content)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(content)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(container)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius)
                .stroke(Color.hairline, lineWidth: bordered ? 0.5 : 0)
        )
    }
}

// MARK: - Preview
#if DEBUG
#Preview("Clock banners") {
    ScrollView {
        VStack(spacing: 16) {
            GlobalClockBanner(status: .skewed(skewMs: 150_000))
            ScanClockBanner(status: .skewed(skewMs: 150_000))
            ScanClockBanner(status: .noSync)
            JudgeClockBanner(status: .skewed(skewMs: 90_000))
            JudgeClockBanner(status: .noSync)
        }
        .padding(DS.hPad)
    }
    .background(Color.paper)
}
#endif
