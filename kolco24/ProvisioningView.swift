//
//  ProvisioningView.swift
//  kolco24
//
//  Провижининг «Привязка чипов» (этап 10). Рендерит `ProvisioningModel`: горизонтальный степпер КП
//  (моно-номер + цветовая точка + «привязано» отметка), hero выбранного КП (цветовая полоса + номер +
//  стоимость + «Уже привязано: N» + зелёные пилюли свежих чипов) и зону сканирования со статусом
//  `ProvisionState` двухтапового флоу. Смена КП сбрасывает pending-write (в модели).
//
//  DEVIATION от Android: `HorizontalPager` + rail-тики заменены списком/степпером (идиоматичный iOS).
//  UI-референс — `ui/admin/ProvisioningScreen.kt`. `.task` стартует прод-сканер; `onDisappear` — `stop()`.
//

import SwiftUI

struct ProvisioningView: View {
    let model: ProvisioningModel

    /// Свайп/выбор КП блокируется, пока идёт bind (иначе pending-write ушёл бы на новый КП).
    private var selectionLocked: Bool {
        if case .binding = model.provisionState { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.checkpoints.isEmpty {
                    emptyState
                } else {
                    stepper
                    if let cp = model.selectedCheckpoint {
                        heroCard(cp)
                    }
                    scanZone
                }
            }
            .padding(.horizontal, DS.hPad)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Color.paper)
        .navigationTitle("Привязка чипов")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.beginScanning() }
        .onDisappear { model.stop() }
    }

    // MARK: - Пустое состояние

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.loaded ? "mappin.slash" : "arrow.triangle.2.circlepath")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.sub)
            Text(model.loaded ? "В легенде нет КП" : "Загрузка КП…")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ink)
            if model.loaded {
                Text("Синхронизируйте гонку на вкладке «Легенда»")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    // MARK: - Степпер КП

    private var stepper: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.checkpoints.enumerated()), id: \.element.id) { idx, cp in
                        stepperTick(cp, index: idx)
                            .id(cp.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedIndex) { _, _ in
                guard let cp = model.selectedCheckpoint else { return }
                withAnimation { proxy.scrollTo(cp.id, anchor: .center) }
            }
        }
    }

    private func stepperTick(_ cp: Checkpoint, index: Int) -> some View {
        let selected = index == model.selectedIndex
        let filled = model.hasAnyChip(cp)
        return Button {
            if !selectionLocked { model.selectCheckpoint(index: index) }
        } label: {
            VStack(spacing: 4) {
                Text(String(format: "%02d", cp.number))
                    .font(.mono(selected ? 20 : 16, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.ink : Color.sub)
                Circle()
                    .fill(filled ? barColorOrGood(cp) : Color.hairline)
                    .frame(width: 7, height: 7)
            }
            .frame(minWidth: 40)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(selected ? Color.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.kolcoOrange : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(selectionLocked)
    }

    /// Цвет заполненной точки: цвет КП, а если он неизвестен/пустой — зелёный (есть чип).
    private func barColorOrGood(_ cp: Checkpoint) -> Color {
        let c = barColor(parseCheckpointColor(cp.color))
        return c == Color.clear ? Color.good : c
    }

    // MARK: - Hero выбранного КП

    private func heroCard(_ cp: Checkpoint) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(barColor(parseCheckpointColor(cp.color)))
                .frame(width: 8)
            VStack(spacing: 8) {
                Text("КП")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sub)
                Text(String(format: "%02d", cp.number))
                    .font(.mono(64, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text(cp.cost.map { "\($0) \(pluralRu(count: $0, one: "балл", few: "балла", many: "баллов"))" } ?? "—")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.sub)

                let bound = model.alreadyBound(cp)
                if bound > 0 {
                    Text("Уже привязано: \(bound)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.sub)
                        .padding(.top, 2)
                }

                let fresh = model.freshLabels(cp)
                if !fresh.isEmpty {
                    freshPills(fresh)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }

    private func freshPills(_ labels: [String]) -> some View {
        // Компактная обёртка пилюль (свежие чипы этой сессии).
        FlowPills(labels: Array(labels.suffix(ProvisioningModel.feedCap)))
    }

    // MARK: - Зона сканирования (статус ProvisionState)

    @ViewBuilder
    private var scanZone: some View {
        switch model.provisionState {
        case .waitingForChip:
            scanCard(icon: "wave.3.right", tint: Color.sub,
                     title: "Приложите чип к телефону",
                     subtitle: "Тап 1 — привязка чипа к этому КП")
        case .binding:
            scanCard(icon: "arrow.triangle.2.circlepath", tint: Color.kolcoOrange,
                     title: "Привязка на сервере…", subtitle: nil, spinning: true)
        case .waitingForWrite:
            scanCard(icon: "square.and.arrow.down", tint: Color.kolcoOrange,
                     title: model.writeHint ?? "Приложите чип ещё раз",
                     subtitle: "Тап 2 — запись кода на чип")
        case let .success(number):
            scanCard(icon: "checkmark.circle.fill", tint: Color.good,
                     title: "Записано: КП \(String(format: "%02d", number))",
                     subtitle: "Переход к следующему КП")
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
}

// MARK: - Вспомогательные вьюхи

/// Непрерывное вращение глифа во время bind.
private struct SpinModifier: ViewModifier {
    let active: Bool
    @State private var angle: Double = 0
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? angle : 0))
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// Простая перенос-по-строкам раскладка зелёных пилюль свежих чипов.
private struct FlowPills: View {
    let labels: [String]

    var body: some View {
        // Компактный `HStack`-перенос через `LazyVGrid` с адаптивными колонками.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.mono(12, weight: .semibold))
                    .foregroundStyle(Color.good)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.good.opacity(0.14))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
private final class PreviewProvisioningScanner: ProvisioningScanning, @unchecked Sendable {
    private var continuation: AsyncStream<TagReading>.Continuation?
    func readings() -> AsyncStream<TagReading> { AsyncStream { self.continuation = $0 } }
    func start() {}
    func stop() { continuation?.finish() }
    func setPendingWrite(uid: String, record: Data) {}
    func clearPendingWrite() {}
    func emit(_ reading: TagReading) { continuation?.yield(reading) }
}

private struct ProvisioningPreviewHost: View {
    @State private var model: ProvisioningModel?
    private let raceId = 7

    var body: some View {
        NavigationStack {
            Group {
                if let model { ProvisioningView(model: model) } else { Color.paper }
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
        try? await env.checkpointStore.replaceAllForRace(raceId: raceId, checkpoints: [
            Checkpoint(id: 1, raceId: raceId, number: 5, cost: 4, type: "kp", description: nil, color: "red"),
            Checkpoint(id: 2, raceId: raceId, number: 12, cost: 6, type: "kp", description: nil, color: "blue"),
            Checkpoint(id: 3, raceId: raceId, number: 33, cost: 9, type: "kp", description: nil, color: "green"),
        ])
        let m = ProvisioningModel(
            raceId: raceId, checkpointStore: env.checkpointStore, tagStore: env.tagStore,
            bindTag: { _, _, _ in .forbidden }, onUnauthorized: {}, feedback: SilentFeedback()
        )
        m.start(scanner: PreviewProvisioningScanner())
        self.model = m
    }
}

#Preview("Light") { ProvisioningPreviewHost() }
#Preview("Dark") { ProvisioningPreviewHost().preferredColorScheme(.dark) }
#endif
