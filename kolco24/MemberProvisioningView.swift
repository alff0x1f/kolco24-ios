//
//  MemberProvisioningView.swift
//  kolco24
//
//  «Записать браслет участника» (iOS-first; план `docs/plans/20260923-member-chip-provisioning.md`).
//  Рендерит `MemberProvisioningModel`: шапка пула `member_tags` (размер / загрузка), зона сканирования
//  со статусом `MemberProvisionState` двухтапового флоу (стили — как у `ProvisioningView`), в
//  `needsNumber` — поле номера (`.numberPad`, префилл `nextNumber`, разбор `parseMemberNumber`,
//  «Привязать» неактивна при `nil`), «Отмена» в `needsNumber`/`waitingForWrite` и лента зелёных
//  пилюль «№101 · A1B2» свежезаписанных браслетов. `.task` стартует прод-сканер; `onDisappear` — `stop()`.
//  Системная NFC-шторка модальна: в `needsNumber` модель приостанавливает сессию (поле номера доступно),
//  а если шторку закрыл пользователь (`!scanning`) — кнопка «Сканировать» (`resumeScanning`).
//

import SwiftUI

struct MemberProvisioningView: View {
    let model: MemberProvisioningModel

    /// Текст поля номера. Префиллится `nextNumber` при каждом входе в `needsNumber`.
    @State private var numberText = ""
    @FocusState private var numberFocused: Bool

    /// UID, ждущий номера (ключ `onChange`: новый браслет в `needsNumber` → новый префилл).
    private var needsNumberUid: String? {
        if case let .needsNumber(uid) = model.provisionState { return uid }
        return nil
    }

    private var canCancel: Bool {
        switch model.provisionState {
        case .needsNumber, .waitingForWrite: return true
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                poolHeader
                scanZone
                if needsNumberUid != nil {
                    numberCard
                }
                if canCancel {
                    cancelButton
                }
                if !model.scanning && needsNumberUid == nil {
                    scanButton
                }
                if !model.freshFeed.isEmpty {
                    freshSection
                }
            }
            .padding(.horizontal, DS.hPad)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.paper)
        .navigationTitle("Браслет участника")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.beginScanning() }
        .onDisappear { model.stop() }
        .onChange(of: needsNumberUid, initial: true) { _, uid in
            if let uid {
                numberText = model.prefillNumber(for: uid).map(String.init) ?? ""
                numberFocused = true
            } else {
                numberFocused = false
            }
        }
    }

    // MARK: - Шапка пула

    private var poolHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: model.loaded ? "person.2.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.sub)
            Text(model.loaded
                 ? "Браслетов в базе: \(model.poolSize)"
                 : "Загрузка браслетов…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.sub)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    // MARK: - Зона сканирования (статус MemberProvisionState)

    @ViewBuilder
    private var scanZone: some View {
        switch model.provisionState {
        case .waitingForChip:
            scanCard(icon: "wave.3.right", tint: Color.sub,
                     title: model.loaded ? "Приложите браслет к телефону" : "Загрузка…",
                     subtitle: "Тап 1 — получение кода с сервера")
        case let .needsNumber(uid):
            scanCard(icon: "number", tint: Color.kolcoOrange,
                     title: "Браслет \(chipTokenLabel(uid: uid)) не найден",
                     subtitle: "Введите номер участника")
        case let .binding(_, number):
            scanCard(icon: "arrow.triangle.2.circlepath", tint: Color.kolcoOrange,
                     title: "Привязка на сервере…",
                     subtitle: number.map { "Номер \($0)" }, spinning: true)
        case let .waitingForWrite(_, number):
            scanCard(icon: "square.and.arrow.down", tint: Color.kolcoOrange,
                     title: model.writeHint ?? memberWriteAgainHint,
                     subtitle: "Тап 2 — запись кода, участник №\(number)")
        case let .success(number):
            scanCard(icon: "checkmark.circle.fill", tint: Color.good,
                     title: "Записано: №\(number)",
                     subtitle: "Можно прикладывать следующий браслет")
        case let .failed(reason):
            scanCard(icon: "xmark.circle.fill", tint: Color.brandRed,
                     title: "Ошибка", subtitle: reason)
        }
    }

    private func scanCard(icon: String, tint: Color, title: String, subtitle: String?, spinning: Bool = false) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(tint)
                    .modifier(SpinModifier(active: spinning))
            }
            .frame(width: 54, height: 54)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    // MARK: - Ввод номера (needsNumber)

    private var numberCard: some View {
        let parsed = parseMemberNumber(numberText)
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("№")
                    .font(.mono(22, weight: .bold))
                    .foregroundStyle(Color.sub)
                TextField("Номер", text: $numberText)
                    .keyboardType(.numberPad)
                    .font(.mono(28, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .focused($numberFocused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.paper)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.kolcoOrange, lineWidth: 1.5)
            )

            Button {
                guard let n = parsed else { return }
                numberFocused = false
                model.confirmNumber(n)
            } label: {
                Text("Привязать")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(parsed == nil ? Color.sub.opacity(0.3) : Color.kolcoOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(parsed == nil)
        }
        .padding(16)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    private var cancelButton: some View {
        Button {
            numberFocused = false
            model.cancel()
        } label: {
            Text("Отмена")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.brandRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    /// Шторку закрыл пользователь (или NFC недоступен) — открыть сессию заново; pending-write сохранён.
    private var scanButton: some View {
        Button {
            model.resumeScanning()
        } label: {
            Label("Сканировать", systemImage: "wave.3.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.kolcoOrange)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Лента свежих браслетов

    private var freshSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Записано в этой сессии: \(model.freshFeed.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.sub)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(model.freshFeed) { item in
                    Text("№\(item.number) · \(chipTokenLabel(uid: item.uid))")
                        .font(.mono(12, weight: .semibold))
                        .foregroundStyle(Color.good)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.good.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }
}

// MARK: - Preview

#if DEBUG
private final class PreviewMemberScanner: ProvisioningScanning, @unchecked Sendable {
    private var continuation: AsyncStream<TagReading>.Continuation?
    func readings() -> AsyncStream<TagReading> { AsyncStream { self.continuation = $0 } }
    func start() {}
    func stop() { continuation?.finish() }
    func setPendingWrite(uid: String, record: Data) {}
    func clearPendingWrite() {}
    func emit(_ reading: TagReading) { continuation?.yield(reading) }
}

private struct MemberProvisioningPreviewHost: View {
    @State private var model: MemberProvisioningModel?
    private let raceId = 7

    var body: some View {
        NavigationStack {
            Group {
                if let model { MemberProvisioningView(model: model) } else { Color.paper }
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
        try? await env.memberTagStore.insertAll([
            MemberTag(raceId: raceId, nfcUid: "04A1B2C3D4E5F6", number: 101),
            MemberTag(raceId: raceId, nfcUid: "04FFEEDDCCBBAA", number: 102),
        ])
        // До деплоя эндпоинта сервер отвечает 404 → экран просит номер.
        let m = MemberProvisioningModel(
            raceId: raceId, memberTagStore: env.memberTagStore,
            bindMemberTag: { _, _, _ in .error(code: 404) }, onUnauthorized: {}, feedback: SilentFeedback()
        )
        m.start(scanner: PreviewMemberScanner())
        self.model = m
    }
}

#Preview("Light") { MemberProvisioningPreviewHost() }
#Preview("Dark") { MemberProvisioningPreviewHost().preferredColorScheme(.dark) }
#endif
