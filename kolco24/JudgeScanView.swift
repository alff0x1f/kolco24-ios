//
//  JudgeScanView.swift
//  kolco24
//
//  Судейский экран «Отметка старта/финиша» (этап 10). Рендерит состояние `JudgeScanModel`
//  (хост-редьюсер): крупные живые часы (локальная TZ, `Font.mono`), статус последнего скана
//  (зелёный `№N` / amber «Это чип КП» / красный «Неизвестный чип» + uid), лента недавних (до 20)
//  и плейт «Синхронизируйте гонку», когда пул `member_tags` не синхронизирован.
//
//  `.task` стартует привязанный прод-сканер (`model.beginScanning()`); `onDisappear` — `model.stop()`
//  (инвалидация NFC-сессии + финальный flush судейского дренажа). Разрешений не запрашиваем —
//  NFC-шторка iOS системная. UI-референс — `ui/admin/JudgeScanScreen.kt`.
//

import SwiftUI

struct JudgeScanView: View {
    let model: JudgeScanModel

    private var title: String {
        model.eventType == "finish" ? "Отметка финиша" : "Отметка старта"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                clockHero

                if model.needsSync {
                    syncPlate
                }

                statusCard

                if !model.feed.isEmpty {
                    feedSection
                }
            }
            .padding(.horizontal, DS.hPad)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { model.beginScanning() }
        .onDisappear { model.stop() }
    }

    // MARK: - Живые часы

    private var clockHero: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                Text(clockString(context.date))
                    .font(.mono(52, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("Прикладывайте браслеты участников")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background { DarkHeroBackground() }
            .clipShape(RoundedRectangle(cornerRadius: DS.heroRadius))
            .shadow(color: Color.heroShadow, radius: 30, x: 0, y: 14)
        }
    }

    private func clockString(_ date: Date) -> String {
        AdminClockFormat.clock(date)
    }

    // MARK: - Плейт «Синхронизируйте гонку»

    private var syncPlate: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.brandRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("Синхронизируйте гонку")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brandRed)
                Text("Пул браслетов ещё не загружен — отметки не распознаются.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandRed.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
    }

    // MARK: - Статус последнего скана

    private var statusCard: some View {
        let s = statusStyle(model.lastResult)
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(s.color.opacity(0.15))
                Image(systemName: s.icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(s.color)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(s.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(s.color)
                if let sub = s.subtitle {
                    Text(sub)
                        .font(.mono(12, weight: .medium))
                        .foregroundStyle(Color.sub)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    // MARK: - Лента недавних

    private var feedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Недавние · \(model.feed.count)")
                .padding(.bottom, 0)
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
}

// MARK: - Статус-стиль по результату

private struct StatusStyle {
    let title: String
    let subtitle: String?
    let icon: String
    let color: Color
}

private func statusStyle(_ result: JudgeScanResult?) -> StatusStyle {
    switch result {
    case nil, .poolNotReady:
        return StatusStyle(title: "Ожидание", subtitle: "Приложите браслет", icon: "wave.3.right", color: Color.sub)
    case let .recorded(_, number):
        return StatusStyle(title: "№\(number)", subtitle: "Отметка записана", icon: "checkmark.circle.fill", color: Color.good)
    case .kpChip:
        return StatusStyle(title: "Это чип КП", subtitle: "Приложите браслет участника", icon: "exclamationmark.triangle.fill", color: Color.amber)
    case let .unknownChip(uid):
        return StatusStyle(title: "Неизвестный чип", subtitle: uid, icon: "xmark.circle.fill", color: Color.brandRed)
    }
}

// MARK: - Ряд ленты

private struct FeedRow: View {
    let item: JudgeScanModel.FeedItem

    var body: some View {
        let s = statusStyle(item.result)
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

// MARK: - Preview

#if DEBUG
/// Превью-сканер — тест-эквивалент `FakeChipScanner`: синхронно `emit`'ит `TagReading` в стрим модели.
private final class PreviewJudgeScanner: ChipScanning, @unchecked Sendable {
    private var continuation: AsyncStream<TagReading>.Continuation?
    func readings() -> AsyncStream<TagReading> { AsyncStream { self.continuation = $0 } }
    func start() {}
    func stop() { continuation?.finish() }
    func emit(_ reading: TagReading) { continuation?.yield(reading) }
}

private struct JudgeScanPreviewHost: View {
    @State private var model: JudgeScanModel?

    private let raceId = 7

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    JudgeScanView(model: model)
                } else {
                    Color.paper
                }
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

        // Пул из одного браслета — иначе скан классифицируется как poolNotReady/unknown.
        try? await env.memberTagStore.insertAll([
            MemberTag(raceId: raceId, nfcUid: "W1", number: 101)
        ])

        let scanner = PreviewJudgeScanner()
        let model = JudgeScanModel(
            raceId: raceId, eventType: "start",
            judgeScanStore: env.judgeScanStore,
            repository: env.judgeScanUploadRepository,
            memberTagsRepository: env.memberTagsRepository,
            feedback: SilentFeedback(),
            installId: env.installId,
            drainIntervalMs: 100_000
        )
        model.start(scanner: scanner)
        self.model = model

        func sample() -> TimeSample { TimeSample(wallMs: 1_700_000_000_000, elapsedMs: 0, trustedMs: nil, bootCount: nil) }
        try? await Task.sleep(for: .milliseconds(400))
        scanner.emit(TagReading(code: nil, uid: "W1", sample: sample()))
    }
}

#Preview("Light") {
    JudgeScanPreviewHost()
}

#Preview("Dark") {
    JudgeScanPreviewHost()
        .preferredColorScheme(.dark)
}
#endif
