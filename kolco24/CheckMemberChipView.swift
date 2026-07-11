//
//  CheckMemberChipView.swift
//  kolco24
//
//  Read-only проверка браслетов участников «Проверка браслетов» (этап 10). Рендерит состояние
//  `MemberChipCheckModel`: hero последнего скана (зелёный `№N` для `ok` / amber «Это чип КП» для
//  `kpChip` / красный «Неизвестный чип» для `unknown`) + idle-строка с размером пула (`0` — признак
//  «пул не синхронизирован») + лента недавних (до 20). Полностью оффлайн, ничего не пишет.
//
//  `.task` стартует привязанный прод-сканер; `onDisappear` — `model.stop()`. UI-референс —
//  `ui/admin/CheckMemberChipScreen.kt`.
//

import SwiftUI

struct CheckMemberChipView: View {
    let model: MemberChipCheckModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                poolLine

                if !model.feed.isEmpty {
                    feedSection
                }
            }
            .padding(.horizontal, DS.hPad)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color.paper)
        .navigationTitle("Проверка браслетов")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.beginScanning() }
        .onDisappear { model.stop() }
    }

    // MARK: - Hero последнего скана

    private var heroCard: some View {
        let s = statusStyle(model.lastResult)
        return VStack(spacing: 12) {
            ZStack {
                Circle().fill(s.color.opacity(0.15))
                Image(systemName: s.icon)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(s.color)
            }
            .frame(width: 68, height: 68)
            Text(s.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(s.color)
            if let sub = s.subtitle {
                Text(sub)
                    .font(.mono(13, weight: .medium))
                    .foregroundStyle(Color.sub)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    // MARK: - Строка пула

    private var poolLine: some View {
        HStack(spacing: 10) {
            Image(systemName: model.poolSize > 0 ? "person.2.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.poolSize > 0 ? Color.sub : Color.brandRed)
            Text(model.poolSize > 0
                 ? "В пуле \(model.poolSize) \(pluralRu(count: model.poolSize, one: "браслет", few: "браслета", many: "браслетов"))"
                 : "Пул не синхронизирован — синхронизируйте гонку")
                .font(.system(size: 13))
                .foregroundStyle(model.poolSize > 0 ? Color.sub : Color.brandRed)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.poolSize > 0 ? Color.card : Color.brandRed.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
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
        let item: MemberChipCheckModel.FeedItem

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
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm:ss"
            return f.string(from: Date(timeIntervalSince1970: Double(wallMs) / 1000))
        }
    }
}

// MARK: - Стиль статуса по результату

private struct StatusStyle {
    let title: String
    let subtitle: String?
    let icon: String
    let color: Color
}

private func statusStyle(_ result: MemberChipCheckResult?) -> StatusStyle {
    switch result {
    case nil:
        return StatusStyle(title: "Ожидание", subtitle: "Приложите браслет", icon: "wave.3.right", color: Color.sub)
    case let .ok(_, number):
        return StatusStyle(title: "№\(number)", subtitle: "Участник в пуле", icon: "checkmark.circle.fill", color: Color.good)
    case let .kpChip(uid):
        return StatusStyle(title: "Это чип КП", subtitle: uid, icon: "exclamationmark.triangle.fill", color: Color.amber)
    case let .unknown(uid):
        return StatusStyle(title: "Неизвестный чип", subtitle: uid, icon: "xmark.circle.fill", color: Color.brandRed)
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

private struct CheckMemberChipPreviewHost: View {
    @State private var model: MemberChipCheckModel?
    private let raceId = 7

    var body: some View {
        NavigationStack {
            Group {
                if let model { CheckMemberChipView(model: model) } else { Color.paper }
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
        try? await env.memberTagStore.insertAll([MemberTag(raceId: raceId, nfcUid: "W1", number: 101)])
        let scanner = PreviewScanner()
        let model = MemberChipCheckModel(raceId: raceId, memberTagStore: env.memberTagStore,
                                         feedback: SilentFeedback())
        model.start(scanner: scanner)
        self.model = model
        try? await Task.sleep(for: .milliseconds(400))
        scanner.emit(TagReading(code: nil, uid: "W1",
                                sample: TimeSample(wallMs: 1_700_000_000_000, elapsedMs: 0, trustedMs: nil, bootCount: nil)))
    }
}

#Preview("Light") { CheckMemberChipPreviewHost() }
#Preview("Dark") { CheckMemberChipPreviewHost().preferredColorScheme(.dark) }
#endif
