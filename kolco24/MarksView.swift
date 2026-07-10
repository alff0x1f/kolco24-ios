//
//  MarksView.swift
//  kolco24
//
//  Вкладка «Отметки» на реальных данных. Порт ПОВЕДЕНИЯ `ui/marks/MarksScreen.kt`: метрики + сетка
//  тайлов взятий выбранной команды из БД, лестница пустых состояний (выбери команду / привяжи чипы /
//  готов). Данные и derived — из `MarksModel` (наблюдение взятий/КП/агрегатов/привязок).
//
//  Тайл на complete-взятие (oldest-first), существующий дизайн (`NFCTileView`/`PhotoTileView`).
//  `ScanSheet` теперь на реальных данных (этап 5, `ScanModel`); `PhotoTile`/лайтбокс — заглушка (этап 7).
//  «ДО КВ» в метриках —
//  плейсхолдер «—» (источника нет, как в Android). Нудж «привяжи чипы» ведёт на вкладку «Команда»
//  (`onBindChips`).
//

import SwiftUI

// MARK: - MarksView
struct MarksView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: MarksModel?
    /// Скан-модель текущего оверлея; ненулевая ⇒ шит открыт (`.sheet(item:)`). Строится по тапу FAB
    /// через `AppModel.makeScanModel()` (nil, когда команда не выбрана — тогда ведём в выбор команды).
    @State private var scanModel: ScanModel?
    /// Фото-модель текущего кавера; ненулевая ⇒ кавер открыт (`.fullScreenCover(item:)`). Строится по
    /// тапу FAB «Фото» через `AppModel.makePhotoModel()` (nil без команды — ведём в выбор команды).
    @State private var photoModel: PhotoModel?
    /// Точка входа во флоу выбора команды (пробрасывается хостом; в превью — no-op).
    var onChooseTeam: () -> Void = {}
    /// Переход на вкладку «Команда» для привязки чипов (нудж пустого состояния).
    var onBindChips: () -> Void = {}

    var body: some View {
        content
            .background(Color.paper)
            .navigationTitle("Отметки")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: [appModel.selectedRaceId, appModel.selectedTeamId]) {
                if model == nil { model = appModel.makeMarksModel() }
                model?.rebind(teamId: appModel.selectedTeamId, raceId: appModel.selectedRaceId)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FloatingCTAView(onNFC: openScan, onPhoto: openPhoto)
            }
            .sheet(item: $scanModel, onDismiss: flushAfterScan) { model in
                ScanSheet(model: model)
            }
            .fullScreenCover(item: $photoModel, onDismiss: flushAfterScan) { model in
                PhotoFlowView(model: model)
            }
    }

    /// Тап FAB «Фото»: строим фото-модель выбранной команды. Нет команды (`makePhotoModel` → nil) —
    /// снимать некуда, ведём в выбор команды вместо пустого кавера.
    private func openPhoto() {
        if let photo = appModel.makePhotoModel() {
            photoModel = photo
        } else {
            onChooseTeam()
        }
    }

    /// Закрытие скан-оверлея (любой путь: кнопка, свайп, авто-close модели) — дренаж накопленных
    /// взятий выбранной команды (этап 6). Шов живёт здесь, а не в `ScanSheet`: тому доступен только
    /// `ScanModel`, а `AppModel` (с репозиторием) — в `@Environment` этой вьюхи.
    private func flushAfterScan() {
        guard let raceId = appModel.selectedRaceId, let teamId = appModel.selectedTeamId else { return }
        appModel.flushUploads(raceId: raceId, teamId: teamId)
    }

    /// Тап FAB «Отметить КП»: строим скан-модель выбранной команды. Нет команды (`makeScanModel` →
    /// nil) — сканировать некуда, поэтому ведём в выбор команды вместо пустого шита.
    private func openScan() {
        if let scan = appModel.makeScanModel() {
            scanModel = scan
        } else {
            onChooseTeam()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.selectedTeamState {
        case .loading:
            // Подавляем мигание empty-состояния до первой эмиссии observation.
            Color.paper
        case .missing:
            TeamEmptyState(missing: true, onChooseTeam: onChooseTeam)
        case .none:
            marksScreen(team: nil)
        case .present(let team):
            marksScreen(team: team)
        }
    }

    private func marksScreen(team: Team?) -> some View {
        let members = team?.members.sorted { $0.numberInTeam < $1.numberInTeam } ?? []
        let tiles = model?.tiles ?? []
        let hidden = model?.hiddenTakenTokens ?? []
        let emptyState = model?.emptyState(hasTeam: team != nil, members: members) ?? .none

        return ScrollView {
            VStack(spacing: 0) {
                MetricsCard(
                    takenKp: model?.takenKp ?? 0,
                    totalKp: model?.totalKp ?? 0,
                    takenScore: model?.takenScore ?? 0,
                    totalCost: model?.totalCost ?? 0
                )
                .padding(.horizontal, DS.hPad)
                .padding(.bottom, 14)

                if !hidden.isEmpty {
                    HiddenKpNotice(tokens: hidden)
                        .padding(.horizontal, DS.hPad)
                        .padding(.bottom, 14)
                }

                if tiles.isEmpty {
                    MarksEmptyLadder(
                        state: emptyState,
                        boundCount: model?.boundCount(members: members) ?? 0,
                        memberCount: members.count,
                        onChooseTeam: onChooseTeam,
                        onBindChips: onBindChips
                    )
                    .padding(.top, 24)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                            if tile.kind == .nfc {
                                NFCTileView(tile: tile)
                            } else {
                                PhotoTileView(tile: tile)
                            }
                        }
                    }
                    .padding(.bottom, 14)

                    NFCStripView()
                        .padding(.horizontal, DS.hPad)
                        .padding(.bottom, 14)
                }
            }
            .padding(.top, 8)
        }
        .background(Color.paper)
        .refreshable { await appModel.refreshAll() }
    }
}

// MARK: - Metrics Card
private struct MetricsCard: View {
    let takenKp: Int
    let totalKp: Int
    let takenScore: Int
    let totalCost: Int

    // Скрываем «/0», пока сервер не прислал агрегаты легенды (порт гейта `totalKp > 0`).
    private var takenValue: String { totalKp > 0 ? "\(takenKp)/\(totalKp)" : "\(takenKp)" }
    private var scoreValue: String { totalCost > 0 ? "\(takenScore)/\(totalCost)" : "\(takenScore)" }

    var body: some View {
        HStack(spacing: 6) {
            MetricView(label: "Взято", value: takenValue, unit: "КП")
            VDivider()
            MetricView(label: "Сумма", value: scoreValue, unit: "бал.")
            VDivider()
            // «ДО КВ» — плейсхолдер: источника контрольного времени пока нет (как в Android).
            MetricView(label: "До КВ", value: "—")
        }
        .padding(.horizontal, 18)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }
}

// MARK: - Hidden-КП Notice («взято, баллы скрыты»)
private struct HiddenKpNotice: View {
    let tokens: [String]

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.ink.opacity(0.06))
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Взято, баллы пока скрыты")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(tokensLabel(tokens))
                    .font(.mono(12, weight: .semibold))
                    .foregroundStyle(Color.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }
}

// MARK: - Empty Ladder (порт MarksEmpty, NFC-ветки — этап 5)
private struct MarksEmptyLadder: View {
    let state: MarksEmptyState
    let boundCount: Int
    let memberCount: Int
    let onChooseTeam: () -> Void
    let onBindChips: () -> Void

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .chooseTeam:
            emptyContent(
                glyph: "person.3.fill",
                headline: "Отметок пока нет",
                body: "Выберите соревнование и команду — отметки появятся здесь.",
                ctaLabel: "Выбрать команду",
                onCta: onChooseTeam
            )
        case .bindChips:
            emptyContent(
                glyph: "link",
                headline: "Привяжите чипы участникам",
                body: "Отметка засчитывается, только когда отмечены все участники команды. Сейчас с чипом \(boundCount) из \(memberCount).",
                ctaLabel: "Привязать чипы",
                onCta: onBindChips
            )
        case .ready:
            emptyContent(
                glyph: "wave.3.right",
                headline: "Здесь появятся отметки",
                body: "Приложите телефон к метке КП — отметка добавится сюда.",
                ctaLabel: nil,
                onCta: nil
            )
        }
    }

    @ViewBuilder
    private func emptyContent(
        glyph: String,
        headline: String,
        body: String,
        ctaLabel: String?,
        onCta: (() -> Void)?
    ) -> some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        Color.kolcoOrange.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])
                    )
                    .frame(width: 88, height: 88)
                Image(systemName: glyph)
                    .font(.system(size: 34))
                    .foregroundStyle(Color.kolcoOrange.opacity(0.8))
            }

            Text(headline)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 22)

            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(Color.sub)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            if let ctaLabel, let onCta {
                Button(action: onCta) {
                    Text(ctaLabel)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 48)
                        .frame(maxWidth: .infinity)
                        .background(Color.kolcoOrange)
                        .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - NFC Tile
// Dark "chip card": fixed-dark in both themes (like DarkHeroBackground),
// not adaptive tokens. Contactless arcs glyph + big mono number.
private struct NFCTileView: View {
    let tile: MarkTile

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                // background gradient (#171D25 → #232A33, ≈155°) with inset depth
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "171D25"), Color(hex: "232A33")],
                            startPoint: UnitPoint(x: 0.29, y: 0),
                            endPoint: UnitPoint(x: 0.71, y: 1)
                        )
                        .shadow(.inner(color: .black.opacity(0.6), radius: side * 0.1, y: 2))
                        .shadow(.inner(color: .white.opacity(0.04), radius: 0.5, y: -1))
                    )
                // subtle diagonal sheen (white α≈0.025)
                Canvas { ctx, s in
                    let step: CGFloat = 4
                    var x: CGFloat = -s.height
                    while x < s.width + s.height {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x + s.height, y: s.height))
                        ctx.stroke(p, with: .color(Color.white.opacity(0.025)), lineWidth: 1)
                        x += step
                    }
                }
                VStack(spacing: side * 0.04) {
                    ContactlessGlyph()
                        .frame(width: side * 0.38, height: side * 0.38)
                    Text(tile.number)
                        .font(.mono(28, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 0, y: 1)
                }
            }
            .overlay { Rectangle().stroke(Color.white.opacity(0.06), lineWidth: 0.5) }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// Three contactless-payment arcs (matches design_dark.html NFCTile glyph).
private struct ContactlessGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let sx = s.width / 32
            let sy = s.height / 32
            func arc(_ mx: CGFloat, _ my: CGFloat,
                     _ cx: CGFloat, _ cy: CGFloat,
                     _ ex: CGFloat, _ ey: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: mx * sx, y: my * sy))
                p.addQuadCurve(to: CGPoint(x: ex * sx, y: ey * sy),
                               control: CGPoint(x: cx * sx, y: cy * sy))
                return p
            }
            let shading = GraphicsContext.Shading.color(Color(hex: "E6EAF0"))
            let style = StrokeStyle(lineWidth: 2.2 * sx, lineCap: .round)
            ctx.stroke(arc(8, 10, 14, 16, 8, 22), with: shading, style: style)
            ctx.stroke(arc(13, 6, 22, 16, 13, 26), with: shading, style: style)
            ctx.stroke(arc(18, 2, 30, 16, 18, 30), with: shading, style: style)
        }
    }
}

// MARK: - Photo Tile
// Заглушка до этапа 7 (реального фото нет): гладкий градиент с CP-бейджем.
private struct PhotoTileView: View {
    let tile: MarkTile

    private let gradient = LinearGradient(
        colors: [Color(hex: "C7C0A6"), Color(hex: "A8A085")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            gradient
            Canvas { ctx, s in
                let step: CGFloat = 8
                var x: CGFloat = -s.height
                while x < s.width + s.height {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + s.height, y: s.height))
                    ctx.stroke(p, with: .color(Color.white.opacity(0.06)), lineWidth: 2)
                    x += step
                }
            }
            LinearGradient(colors: [.white.opacity(0.06), .black.opacity(0.10)], startPoint: .top, endPoint: .bottom)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            CPBadge(number: tile.number, size: 28)
                .padding(4)
        }
        .overlay { Rectangle().stroke(Color.hairline, lineWidth: 0.5) }
    }
}

// MARK: - NFC Strip
private struct NFCStripView: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.good.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.6 : 0.8)
                    .opacity(pulse ? 0 : 0.5)
                Circle()
                    .fill(Color.good)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 8, height: 8)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
            (
                Text("NFC активен").fontWeight(.semibold).foregroundStyle(Color.ink) +
                Text(" · приложите телефон к КП или чипу команды").foregroundStyle(Color.sub)
            )
            .font(.system(size: 12))
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Floating CTA
private struct FloatingCTAView: View {
    let onNFC: () -> Void
    let onPhoto: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onNFC) {
                HStack(spacing: 8) {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Отметить КП")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.kolcoOrange)
                .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
                .shadow(color: Color.kolcoOrange.opacity(0.55), radius: 20, x: 0, y: 8)
            }
            .buttonStyle(.plain)

            Button(action: onPhoto) {
                HStack(spacing: 6) {
                    Image(systemName: "camera")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.kolcoOrange)
                    Text("Фото")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
                .frame(width: 96, height: 54)
                .background(Color.cardElevated.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.ctaRadius)
                        .stroke(Color.hairline, lineWidth: 0.5)
                )
                .shadow(color: Color.cardShadow, radius: 18, x: 0, y: 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.hPad)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Photo Flow (кавер: пикер → камера по route модели)
/// Контейнер фото-кавера. `NavigationStack` переключает пикер номера КП ↔ камеру по `model.route`
/// (`start()` на входе решает цель — attach vs askNumber). `closeRequested` (коммит) → dismiss кавера;
/// закрытие любым путём триггерит `flushUploads` (этап 6) через `onDismiss` в `MarksView`.
private struct PhotoFlowView: View {
    let model: PhotoModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            switch model.route {
            case .picker:
                PhotoNumberPickerView(model: model)
            case .camera(let attach):
                PhotoCaptureView(model: model, attach: attach)
            }
        }
        .task { await model.start() }
        .onChange(of: model.closeRequested) { _, requested in
            if requested { dismiss() }
        }
    }
}

// MARK: - Preview
#if DEBUG
/// Хост превью фото-флоу: in-memory окружение + пара КП в легенде + фейковый `writeFrame`
/// (синтетические пути, без диска). Камера в симуляторе пуста — превью показывает пикер номера КП.
private struct PhotoFlowPreviewHost: View {
    @State private var model: PhotoModel?

    var body: some View {
        Group {
            if let model {
                PhotoFlowView(model: model)
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

        try? await env.checkpointStore.insertCheckpoints([
            Checkpoint(id: 1, raceId: 7, number: 7, cost: 4, type: "cp", description: "Опушка у ЛЭП", locked: false),
            Checkpoint(id: 2, raceId: 7, number: 12, cost: nil, type: "cp", description: nil, locked: true),
            Checkpoint(id: 3, raceId: 7, number: 23, cost: 6, type: "cp", description: "Брод через ручей", locked: false),
        ])
        model = PhotoModel(
            raceId: 7, teamId: 42, rosterSize: 4,
            checkpointStore: env.checkpointStore, markStore: env.markStore,
            locationProvider: NoLocationProvider(),
            sampleNow: { TimeSample(wallMs: 0, elapsedMs: 0, trustedMs: nil, bootCount: nil) },
            writeFrame: { markId, _ in "marks/\(markId)/\(UUID().uuidString.lowercased()).jpg" },
            deleteFrame: { _ in }
        )
    }
}

#Preview("Photo picker") {
    PhotoFlowPreviewHost()
}
#endif
