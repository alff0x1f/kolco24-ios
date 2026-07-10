//
//  ScanSheet.swift
//  kolco24
//
//  Скан-оверлей «Отметить КП» на реальных данных (этап 5, задача 8). Рендерит состояние `ScanModel`
//  (хост-редьюсер скан-флоу): таймер-хиро от живого 20-с окна, карточка КП «?» → номер+цена после
//  чтения чипа КП, грид слотов из реального ростҫера + `session.present`/буфера, строка диагностики.
//
//  Вход — FAB в `MarksView` (`makeScanModel()`); iOS не имеет постоянного reader mode, поэтому оверлей
//  всегда открывается явно. `.task` стартует прод-сканер (`model.beginScanning()`) и заранее запрашивает
//  гео-разрешение. Любое закрытие (кнопка/свайп/автозакрытие по `closeRequested`) → `model.stop()`
//  (инвалидация NFC-сессии) + плейсхолдер flush-загрузок (этап 6). UI-референс — `ui/scan/ScanScreen.kt`.
//
//  Весь ключевой статус (таймер, номер КП, остаток чипов) держится в верхней трети — под ним встаёт
//  системная NFC-шторка iOS.
//

import SwiftUI

// MARK: - ScanSheet
struct ScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ScanModel

    /// Ростер, отсортированный по слоту (стабильный порядок грида).
    private var roster: [TeamMemberItem] {
        model.roster.sorted { $0.numberInTeam < $1.numberInTeam }
    }
    private var scannedCount: Int { model.scannedSlots.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Sheet handle
                Capsule()
                    .fill(Color.sub.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                header

                // Timer hero — stays at the top so the iOS NFC system sheet doesn't cover it
                TimerHeroView(
                    seconds: Int(model.remainingSeconds.rounded()),
                    total: Int(SCAN_WINDOW_MS / 1000),
                    remainingScans: model.remainingScans,
                    waitingForCheckpoint: !model.canFinish
                )
                .padding(.horizontal, DS.hPad)
                .padding(.top, 4)
                .padding(.bottom, 10)

                // CP card — waiting / identified / done
                CPCardView(
                    number: model.checkpointNumber,
                    cost: model.checkpointCost,
                    completed: model.completed
                )
                .padding(.horizontal, DS.hPad)
                .padding(.bottom, 10)

                // Diagnostic (badKp / unboundChip)
                if let diagnostic = model.diagnostic {
                    DiagnosticLine(text: diagnostic)
                        .padding(.horizontal, DS.hPad)
                        .padding(.bottom, 10)
                }

                // Chips header
                HStack {
                    Text("Чипы команды")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sub)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(scannedCount) / \(roster.count)")
                        .font(.mono(13, weight: .bold))
                        .foregroundStyle(scannedCount == roster.count && !roster.isEmpty ? Color.good : Color.ink)
                }
                .padding(.horizontal, DS.hPad + 2)
                .padding(.bottom, 6)

                chipGrid

                Text("Сканировать чипы можно в любом порядке")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.hPad + 2)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                actions
            }
        }
        .background(Color.paper)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            // Заранее запрашиваем гео-разрешение (один раз, ОС дедупит) и стартуем прод-сканер.
            model.requestGeoPermission()
            model.beginScanning()
        }
        .onChange(of: model.closeRequested) { _, requested in
            if requested { dismiss() }
        }
        .onDisappear {
            // Любое закрытие оверлея инвалидирует NFC-сессию; начатые записи в БД живут в своих Task'ах.
            model.stop()
            // Flush накопленных взятий (этап 6) живёт в `MarksView.sheet(item:onDismiss:)` — у ScanSheet
            // нет доступа к `AppModel`/репозиторию, а `onDismiss` покрывает все пути закрытия шита.
        }
    }

    private var header: some View {
        HStack {
            Color.clear.frame(width: 30)
            Spacer()
            Text("Отметить КП")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.ink)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.sub)
                    .font(.system(size: 24))
            }
        }
        .padding(.horizontal, DS.hPad)
        .padding(.bottom, 4)
    }

    private var chipGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)],
            spacing: 0
        ) {
            ForEach(Array(roster.enumerated()), id: \.element.numberInTeam) { i, member in
                ChipSlotView(
                    name: member.name,
                    chipNumber: model.chipNumbers[member.numberInTeam],
                    filled: model.scannedSlots.contains(member.numberInTeam)
                )
                .overlay(alignment: .trailing) {
                    if i % 2 == 0 {
                        Rectangle().fill(Color.hairline).frame(width: 0.5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if i / 2 < (roster.count - 1) / 2 {
                        Rectangle().fill(Color.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
        .padding(.horizontal, DS.hPad)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Отменить") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.sub.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            Button("Готово") { dismiss() }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(model.canFinish ? Color.kolcoOrange : Color.sub.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(!model.canFinish)
        }
        .padding(.horizontal, DS.hPad)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }
}

// MARK: - CP Card (waiting / identified / done)
private struct CPCardView: View {
    let number: Int?
    let cost: Int?
    let completed: Bool

    var body: some View {
        HStack(spacing: 14) {
            CPBadge(number: number.map(String.init) ?? "?", size: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text("Метка КП")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.sub)
                    .textCase(.uppercase)
                    .tracking(1.2)
                if completed {
                    Text("Готово!")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.good)
                    Text("Все участники отмечены")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sub)
                } else if let number {
                    Text("КП \(number)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text(cost.map { "\($0) баллов" } ?? "—")
                        .font(.mono(12, weight: .semibold))
                        .foregroundStyle(Color.sub)
                } else {
                    Text("КП не отсканирован")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text("Поднесите телефон к чипу на КП")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sub)
                }
            }
            Spacer()
            if completed {
                GreenCheckCircle(size: 34)
            }
        }
        .padding(16)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }
}

// MARK: - Diagnostic line (badKp / unboundChip)
private struct DiagnosticLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.brandRed)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brandRed)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandRed.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
    }
}

// MARK: - Chip Slot
private struct ChipSlotView: View {
    let name: String
    let chipNumber: Int?
    let filled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if filled {
                    Circle()
                        .fill(Color.good)
                        .frame(width: 26, height: 26)
                        .shadow(color: Color.good.opacity(0.25), radius: 4)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .strokeBorder(
                            Color.sub.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                        )
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(filled ? Color.ink : Color.sub)
                    .lineLimit(1)
                if let chipNumber {
                    Text("Чип \(chipNumber)")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Color.sub)
                } else {
                    Text("Нет чипа")
                        .font(.mono(10, weight: .medium))
                        .foregroundStyle(Color.sub.opacity(0.5))
                        .textCase(.uppercase)
                        .tracking(0.4)
                }
            }
            Spacer()
        }
        .padding(11)
        .frame(minHeight: 56)
    }
}

// MARK: - Timer Hero
private struct TimerHeroView: View {
    let seconds: Int
    let total: Int
    let remainingScans: Int
    let waitingForCheckpoint: Bool

    private var progress: Double { min(1.0, total > 0 ? Double(seconds) / Double(total) : 0) }

    /// «Осталось N чип/чипа/чипов» / «Приложите метку КП» / «Все чипы отсканированы» — порт `ScanTimerStrip`.
    private var statusLine: String {
        if waitingForCheckpoint { return "Приложите метку КП" }
        if remainingScans == 0 { return "Все чипы отсканированы" }
        let verb = pluralRu(count: remainingScans, one: "Остался", few: "Осталось", many: "Осталось")
        let chip = pluralRu(count: remainingScans, one: "чип", few: "чипа", many: "чипов")
        return "\(verb) \(remainingScans) \(chip)"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.amber, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Color.amber.opacity(0.5), radius: 6)
                VStack(spacing: 2) {
                    Text("\(seconds)")
                        .font(.mono(26, weight: .bold))
                        .foregroundStyle(.white)
                    Text("сек")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(.uppercase)
                        .tracking(1.1)
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color.good)
                        .frame(width: 6, height: 6)
                        .shadow(color: Color.good.opacity(0.3), radius: 4)
                    Text("Сканируйте")
                        .font(.mono(10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .textCase(.uppercase)
                        .tracking(1.3)
                }
                Text(statusLine)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("Таймер сбрасывается на \(total)\u{00A0}с при каждом скане")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background { DarkHeroBackground() }
        .clipShape(RoundedRectangle(cornerRadius: DS.heroRadius))
        .shadow(color: Color.heroShadow, radius: 36, x: 0, y: 18)
    }
}

// MARK: - Preview
#if DEBUG
/// Превью-сканер: НЕ трогает NFC/железо — тест-эквивалент `FakeChipScanner`, синхронно `emit`'ит
/// заранее собранные `TagReading` в стрим модели, чтобы флоу гонялся в симуляторе без устройства.
private final class PreviewChipScanner: ChipScanning, @unchecked Sendable {
    private var continuation: AsyncStream<TagReading>.Continuation?
    func readings() -> AsyncStream<TagReading> { AsyncStream { self.continuation = $0 } }
    func start() {}
    func stop() { continuation?.finish() }
    func emit(_ reading: TagReading) { continuation?.yield(reading) }
}

/// Хост превью: поднимает in-memory окружение, регистрирует один КП + привязки, строит `ScanModel`
/// поверх РЕАЛЬНЫХ сторов и прогоняет чип КП + пару браслетов через `PreviewChipScanner`.
private struct ScanSheetPreviewHost: View {
    @State private var model: ScanModel?

    private let raceId = 7
    private let teamId = 42

    var body: some View {
        Group {
            if let model {
                ScanSheet(model: model)
            } else {
                Color.paper
            }
        }
        .task { await setUp() }
    }

    private func setUp() async {
        guard model == nil else { return }
        guard let env = try? AppEnvironment.inMemory(transport: { _ in
            (Data(), HTTPURLResponse(
                url: URL(string: "https://preview.invalid")!, statusCode: 500,
                httpVersion: nil, headerFields: nil)!)
        }) else { return }

        let code = Data((0..<16).map { UInt8($0 & 0xFF) })
        try? await env.checkpointStore.insertCheckpoints([
            Checkpoint(id: 100, raceId: raceId, number: 32, cost: 4, type: "cp",
                       description: "КП 32", locked: false)
        ])
        let bid = LegendCrypto.bid(code: code)
        try? await env.tagStore.insertTags([
            Tag(raceId: raceId, bid: bid, checkpointId: 100, checkMethod: "nfc", iv: nil, ct: nil)
        ])
        try? await env.memberChipBindingStore.upsert(
            MemberChipBinding(teamId: teamId, numberInTeam: 1, nfcUid: "M1", participantNumber: 101))
        try? await env.memberChipBindingStore.upsert(
            MemberChipBinding(teamId: teamId, numberInTeam: 2, nfcUid: "M2", participantNumber: 102))

        let roster = [
            TeamMemberItem(name: "Маленков А.", numberInTeam: 1),
            TeamMemberItem(name: "Иванов И.", numberInTeam: 2),
            TeamMemberItem(name: "Сидоров П.", numberInTeam: 3),
        ]
        let scanner = PreviewChipScanner()
        // Окно живо: elapsedNowMs держим на 0, чтения штампуем нулём — таймер не истекает в превью.
        let model = ScanModel(
            raceId: raceId, teamId: teamId, roster: roster,
            legendRepository: env.legendRepository, markStore: env.markStore,
            bindingStore: env.memberChipBindingStore,
            locationProvider: NoLocationProvider(), feedback: SilentFeedback(),
            elapsedNowMs: { 0 }
        )
        model.start(scanner: scanner)
        self.model = model

        func sample() -> TimeSample { TimeSample(wallMs: 0, elapsedMs: 0, trustedMs: nil, bootCount: nil) }
        try? await Task.sleep(for: .milliseconds(400))
        scanner.emit(TagReading(code: code, uid: "CP", sample: sample()))
        try? await Task.sleep(for: .milliseconds(500))
        scanner.emit(TagReading(code: nil, uid: "M1", sample: sample()))
    }
}

#Preview("Light") {
    ScanSheetPreviewHost()
}

#Preview("Dark") {
    ScanSheetPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
