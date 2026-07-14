//
//  CheckChipView.swift
//  kolco24
//
//  Read-only проверка КП-чипов «Проверка чипов КП» (этап 10). Рендерит состояние `ChipCheckModel`:
//  hero последнего скана (для `ok` — цветовая полоса + номер КП + стоимость + `bid · checkMethod` +
//  «На этом КП ещё N чипов» + UID с diff-подсветкой изменившихся nibbles; для `noCode`/`unknownChip`/
//  `inconsistent` — amber/red статус-hero) + лента недавних (до 20). Полностью оффлайн, ничего не пишет.
//
//  `.task` стартует привязанный прод-сканер; `onDisappear` — `model.stop()`. UI-референс —
//  `ui/admin/CheckChipScreen.kt`.
//

import SwiftUI

struct CheckChipView: View {
    let model: ChipCheckModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard

                if !model.feed.isEmpty {
                    feedSection
                }
            }
            .padding(.horizontal, DS.hPad)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color.paper)
        .navigationTitle("Проверка чипов КП")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.beginScanning() }
        .onDisappear { model.stop() }
    }

    // MARK: - Hero последнего скана

    @ViewBuilder
    private var heroCard: some View {
        switch model.lastResult {
        case nil:
            waitingHero
        case let .ok(uid, number, cost, color, bid, checkMethod, chipsOnKp):
            okHero(uid: uid, number: number, cost: cost, color: color,
                   bid: bid, checkMethod: checkMethod, chipsOnKp: chipsOnKp)
        case let .noCode(uid):
            messageHero(color: Color.amber, icon: "questionmark.circle.fill",
                        title: "Чистый чип", uid: uid, diagnostic: "Кода КП не прочитано")
        case let .unknownChip(uid, bid):
            messageHero(color: Color.brandRed, icon: "xmark.circle.fill",
                        title: "Неизвестный чип", uid: uid, diagnostic: "bid \(bid) — нет в этой гонке")
        case let .inconsistent(uid, bid, checkpointId):
            messageHero(color: Color.brandRed, icon: "exclamationmark.triangle.fill",
                        title: "Рассинхрон легенды", uid: uid,
                        diagnostic: "bid \(bid) → КП id \(checkpointId) отсутствует")
        }
    }

    private var waitingHero: some View {
        VStack(spacing: 8) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.sub)
            Text("Приложите чип КП")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text(model.loaded ? "Легенда загружена" : "Загрузка легенды…")
                .font(.system(size: 12))
                .foregroundStyle(Color.sub)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    private func okHero(
        uid: String, number: Int, cost: Int?, color: CheckpointColor?,
        bid: String, checkMethod: String, chipsOnKp: Int
    ) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(barColor(color))
                .frame(width: 8)
            VStack(spacing: 8) {
                Text("КП")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sub)
                Text(String(format: "%02d", number))
                    .font(.mono(72, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text(cost.map { "\($0) \(pluralRu(count: $0, one: "балл", few: "балла", many: "баллов"))" } ?? "—")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.sub)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                    Text("Привязан корректно")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(Color.good)
                .padding(.top, 4)

                uidDiffView(uid, fontSize: 17)
                    .padding(.top, 4)

                let others = max(chipsOnKp - 1, 0)
                if others > 0 {
                    Text("На этом КП ещё \(others) \(pluralRu(count: others, one: "чип", few: "чипа", many: "чипов"))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sub)
                }
                Text("\(bid) · \(checkMethod)")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Color.sub)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    private func messageHero(color: Color, icon: String, title: String, uid: String, diagnostic: String) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 56, height: 56)
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
            uidDiffView(uid, fontSize: 16)
            Text(diagnostic)
                .font(.system(size: 12))
                .foregroundStyle(Color.sub)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    /// UID с diff-подсветкой: nibbles из `model.changed` — красным/жирным, остальные приглушённо.
    private func uidDiffView(_ uid: String, fontSize: CGFloat) -> some View {
        let chars = Array(uid)
        return HStack(spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { idx, ch in
                Text(String(ch))
                    .font(.mono(fontSize, weight: model.changed.contains(idx) ? .bold : .regular))
                    .foregroundStyle(model.changed.contains(idx) ? Color.brandRed : Color.sub)
            }
        }
    }

    // MARK: - Лента недавних

    private var feedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Недавние · \(model.feed.count)")
            VStack(spacing: 0) {
                ForEach(Array(model.feed.enumerated()), id: \.element.id) { idx, item in
                    FeedRow(item: item)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    if idx < model.feed.count - 1 {
                        Rectangle().fill(Color.hairline).frame(height: 0.5)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
            .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
        }
    }

    private struct FeedRow: View {
        let item: ChipCheckModel.FeedItem

        var body: some View {
            let s = feedStyle(item.result)
            HStack(spacing: 12) {
                Image(systemName: s.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(s.color)
                    .frame(width: 22)
                Text(s.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(timeString(item.atWallMs))
                    .font(.mono(12, weight: .medium))
                    .foregroundStyle(Color.sub)
            }
        }

        private func timeString(_ wallMs: Int64) -> String {
            AdminClockFormat.time(wallMs)
        }
    }
}

// MARK: - Стиль строки ленты + маппинг цвета КП

private struct FeedStyle {
    let title: String
    let icon: String
    let color: Color
}

private func feedStyle(_ result: ChipCheckResult) -> FeedStyle {
    switch result {
    case let .ok(_, number, _, _, _, _, _):
        return FeedStyle(title: "КП \(String(format: "%02d", number))", icon: "checkmark.circle.fill", color: Color.good)
    case .noCode:
        return FeedStyle(title: "Чистый чип", icon: "questionmark.circle.fill", color: Color.amber)
    case .unknownChip:
        return FeedStyle(title: "Неизвестный чип", icon: "xmark.circle.fill", color: Color.brandRed)
    case .inconsistent:
        return FeedStyle(title: "Рассинхрон", icon: "exclamationmark.triangle.fill", color: Color.brandRed)
    }
}

/// `CheckpointColor → Color` — фиксированные декоративные оттенки (одинаковы в light/dark), зеркало
/// `barColor()` (`LegendScreen.kt` :594). `nil` (неизвестный/пустой токен) → прозрачный.
/// Семантика цвета КП едина в обеих темах (прецедент токена `amber`), а насыщенные оттенки
/// (red/blue/yellow/purple) читаются на тёмном фоне — поэтому оставлены литералами, не токенами.
func barColor(_ color: CheckpointColor?) -> Color {
    switch color {
    case .red: return Color(hex: "E53935")
    case .blue: return Color(hex: "1E88E5")
    case .green: return Color.good
    case .yellow: return Color(hex: "F4B400")
    case .orange: return Color.kolcoOrange
    case .purple: return Color(hex: "8E44AD")
    case nil: return Color.clear
    }
}

// MARK: - Preview

#if DEBUG
private final class PreviewScanner: ChipScanning, @unchecked Sendable {
    private var continuation: AsyncStream<TagReading>.Continuation?
    func readings() -> AsyncStream<TagReading> { AsyncStream { self.continuation = $0 } }
    func start() {}
    func stop() { continuation?.finish() }
    func emit(_ reading: TagReading) { continuation?.yield(reading) }
}

private struct CheckChipPreviewHost: View {
    @State private var model: ChipCheckModel?
    private let raceId = 7

    var body: some View {
        NavigationStack {
            Group {
                if let model { CheckChipView(model: model) } else { Color.paper }
            }
        }
        .task { await setUp() }
    }

    private func setUp() async {
        guard model == nil,
              let env = try? AppEnvironment.inMemory(transport: { _ in
                  (Data(), HTTPURLResponse(url: URL(string: "https://preview.invalid")!,
                                           statusCode: 500, httpVersion: nil, headerFields: nil)!)
              }) else { return }
        let code = Data((0..<16).map { UInt8($0) })
        let bid = LegendCrypto.bid(code: code)
        try? await env.checkpointStore.replaceAllForRace(raceId: raceId, checkpoints: [
            Checkpoint(id: 10, raceId: raceId, number: 7, cost: 8, type: "kp", description: nil, color: "red")
        ])
        try? await env.tagStore.replaceAllForRace(raceId: raceId, tags: [
            Tag(raceId: raceId, bid: bid, checkpointId: 10, checkMethod: "nfc")
        ])
        let scanner = PreviewScanner()
        let model = ChipCheckModel(raceId: raceId, tagStore: env.tagStore,
                                   checkpointStore: env.checkpointStore, feedback: SilentFeedback())
        model.start(scanner: scanner)
        self.model = model
        try? await Task.sleep(for: .milliseconds(400))
        scanner.emit(TagReading(code: code, uid: "0411223344AABB",
                                sample: TimeSample(wallMs: 1_700_000_000_000, elapsedMs: 0, trustedMs: nil, bootCount: nil)))
    }
}

#Preview("Light") { CheckChipPreviewHost() }
#Preview("Dark") { CheckChipPreviewHost().preferredColorScheme(.dark) }
#endif
