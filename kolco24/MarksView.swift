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
    /// Открытый лайтбокс (ненулевой ⇒ `fullScreenCover`); несёт глобальную ленту кадров и стартовый
    /// индекс (первый кадр тапнутого тайла).
    @State private var lightbox: LightboxContext?
    /// Празднование взятия (этап 11): `ScanSheet.onCompleted` взводит `pendingCelebration` (шит ещё жив),
    /// `onDismiss` переносит его в `celebrating` — конфетти стартует поверх сетки, когда шит уже ушёл.
    @State private var pendingCelebration = false
    @State private var celebrating = false
    /// Reduce Motion → конфетти не показываем (фанфара уже отыграла из `ScanModel`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Точка входа во флоу выбора команды (пробрасывается хостом; в превью — no-op).
    var onChooseTeam: () -> Void = {}
    /// Переход на вкладку «Команда» для привязки чипов (нудж пустого состояния).
    var onBindChips: () -> Void = {}

    var body: some View {
        content
            .overlay {
                // Празднование поверх сетки; без хит-теста — FAB «Фото»/«Отметить КП» кликабельны сразу.
                ConfettiOverlay(running: celebrating)
                    .allowsHitTesting(false)
            }
            .background(Color.paper)
            .navigationTitle("Отметки")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: [appModel.selectedRaceId, appModel.selectedTeamId]) {
                if model == nil { model = appModel.makeMarksModel() }
                model?.rebind(teamId: appModel.selectedTeamId, raceId: appModel.selectedRaceId)
            }
            .task(id: celebrating) {
                // Автосброс празднования через длительность конфетти (~2.8 с).
                guard celebrating else { return }
                try? await Task.sleep(for: .milliseconds(2800))
                celebrating = false
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FloatingCTAView(onNFC: openScan, onPhoto: openPhoto)
            }
            .sheet(item: $scanModel, onDismiss: onScanDismiss) { model in
                ScanSheet(
                    model: model,
                    clockStatus: appModel.clockStatus,
                    onCompleted: { pendingCelebration = true }
                )
            }
            .fullScreenCover(item: $photoModel, onDismiss: flushAfterScan) { model in
                PhotoFlowView(model: model)
            }
            .fullScreenCover(item: $lightbox) { ctx in
                PhotoLightboxView(
                    photos: ctx.photos,
                    initialIndex: ctx.initialIndex,
                    urlFor: { rel in model?.photoURL(rel) }
                )
            }
    }

    /// Тап по тайлу с кадрами: открыть лайтбокс на глобальной ленте, стартуя с первого кадра тайла.
    /// Индекс ищем по объектному равенству кадра (путь+тайл) в общей ленте — свайп затем листает по всем.
    private func openLightbox(tile: MarkTile) {
        guard let model, let first = tile.photoPaths.first else { return }
        let photos = model.lightboxPhotos
        let start = photos.firstIndex { $0.path == first && $0.tile == tile } ?? 0
        lightbox = LightboxContext(photos: photos, initialIndex: start)
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

    /// Закрытие скан-шита: дренаж (этап 6) + празднование (этап 11). Конфетти стартуем здесь, когда шит
    /// уже ушёл — `pendingCelebration` взведён `ScanSheet.onCompleted` (успешное завершение). Reduce Motion
    /// подавляет визуал (фанфара уже отыграла из `ScanModel`).
    private func onScanDismiss() {
        flushAfterScan()
        if pendingCelebration {
            pendingCelebration = false
            if !reduceMotion { celebrating = true }
        }
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

                if let review = model?.photoReview {
                    PhotoReviewNotice(summary: review)
                        .padding(.horizontal, DS.hPad)
                        .padding(.bottom, 14)
                }

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
                            // Порт `ColorTile`: тайл с кадрами (любого вида — фото-взятие ИЛИ NFC-взятие
                            // с доклеенным фото) показывает первый кадр и открывает лайтбокс; голое
                            // NFC-взятие остаётся chip-картой.
                            if tile.photoCount > 0 {
                                PhotoTileView(
                                    tile: tile,
                                    urlFor: { rel in model?.photoURL(rel) },
                                    onTap: { openLightbox(tile: tile) }
                                )
                            } else {
                                NFCTileView(tile: tile)
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
            MetricView(label: "Взято КП", value: takenValue)
            VDivider()
            MetricView(label: "Баллов", value: scoreValue)
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

// MARK: - Tile KP Token
// Единое обозначение КП тайла (nfc и фото): крупный центрированный mono-токен
// «стоимость-номер» (голый номер при нулевой цене). Белый с тенью — рассчитан
// на тёмную подложку (chip card / затенённый кадр).
private struct TileKpToken: View {
    let tile: MarkTile

    var body: some View {
        Text(markTileToken(tile))
            .font(.mono(28, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 0, y: 1)
            .padding(.horizontal, 6)
    }
}

// MARK: - Tile Color Corner
// Цветной уголок дисциплины КП (top-left). КП без цвета уголка не несёт.
// Не общий `barColor`: там green/orange — адаптивные токены (по теме системы),
// а плитка fixed-dark в обеих темах — уголок не должен менять яркость при
// неизменном фоне. Все шесть цветов заякорены литералами (green/orange — их
// тёмнотемные варианты, читаемые на графите).
private struct TileColorCorner: View {
    let color: CheckpointColor?

    private var fill: Color {
        switch color {
        case .red: return Color(hex: "E53935")
        case .blue: return Color(hex: "1E88E5")
        case .green: return Color(hex: "34C759")
        case .yellow: return Color(hex: "F4B400")
        case .orange: return Color(hex: "F0763C")
        case .purple: return Color(hex: "8E44AD")
        case nil: return Color.clear
        }
    }

    var body: some View {
        if color != nil {
            Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: 22, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 22))
                p.closeSubpath()
            }
            .fill(fill)
            .frame(width: 22, height: 22)
        }
    }
}

// MARK: - NFC Tile
// Dark "chip card": fixed-dark in both themes (like DarkHeroBackground),
// not adaptive tokens. Big mono KP token.
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
                // subtle diagonal sheen; направление «/» — параллельно
                // гипотенузе цветного уголка (top-left), а не поперёк неё
                Canvas { ctx, s in
                    let step: CGFloat = 7
                    var x: CGFloat = 0
                    while x < s.width + s.height {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x - s.height, y: s.height))
                        ctx.stroke(p, with: .color(Color.white.opacity(0.075)), lineWidth: 1)
                        x += step
                    }
                }
                TileKpToken(tile: tile)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(tile.time)
                    .font(.mono(10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
            }
            .overlay(alignment: .topLeading) {
                TileColorCorner(color: tile.color)
            }
            .overlay { Rectangle().stroke(Color.white.opacity(0.06), lineWidth: 0.5) }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Photo Tile
// Реальный тайл фото-взятия (порт `PhotoTileBody`): первый кадр во всю плитку (thumb с фолбэком на
// полный кадр), тёмный градиент-«сиденье» под ним (и заглушка при нечитаемом файле), равномерное
// затенение кадра + центральный КП-токен (как на nfc-плитке), нижний скрим + время каптионом,
// глиф камеры top-right ТОЛЬКО у photo-взятия, бейдж «+N» скрытых кадров bottom-left.
// Тап открывает лайтбокс (тайл используется лишь при `photoCount > 0`).
private struct PhotoTileView: View {
    let tile: MarkTile
    let urlFor: (String) -> URL?
    let onTap: () -> Void

    /// Абсолютный URL первого кадра: предпочитаем `<uuid>.thumb.jpg` (дешевле декод при сетке тайлов),
    /// фолбэк на полный кадр (кадры до появления тумб / сбой тумбы). Один stat на тайл.
    private var firstFrameURL: URL? {
        guard let rel = tile.photoPaths.first else { return nil }
        if let thumb = urlFor(PhotoPaths.thumbPathOf(rel)),
           FileManager.default.fileExists(atPath: thumb.path) {
            return thumb
        }
        return urlFor(rel)
    }

    var body: some View {
        ZStack {
            // Charcoal «сиденье» — показывается, пока кадр грузится / если файл отсутствует.
            LinearGradient(
                colors: [Color(hex: "1D242D"), Color(hex: "2A323C")],
                startPoint: .top, endPoint: .bottom
            )
            if let url = firstFrameURL, let image = UIImage(contentsOfFile: url.path) {
                // Кадр — оверлеем над нулевым слоем: scaledToFill отдаёт layout-у размер больше
                // предложенного (портретный кадр выше квадрата), и ZStack раздувался бы по нему.
                Color.clear.overlay(
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                )
            } else {
                // Кап-заглушка при нечитаемом файле (тот же тёмный фон + глиф фото).
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))
            }
            // Равномерное затенение кадра — центральный белый КП-токен должен
            // читаться на любом снимке (светлое небо, снег). Тон — графит NFC-карты,
            // не чистый чёрный: холодный оттенок сводит фото в один регистр с
            // тёмными nfc-плитками, не давая грязно-серого на тёплых кадрах.
            Color(hex: "171D25").opacity(0.45)
            // Нижний скрим — время читается каптионом над яркой нижней кромкой кадра.
            VStack {
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(maxHeight: .infinity)
            }
            TileKpToken(tile: tile)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(alignment: .topLeading) {
            TileColorCorner(color: tile.color)
        }
        .overlay(alignment: .topTrailing) {
            // Глиф камеры — эксклюзив photo-взятия (NFC-взятие с фото им не помечается).
            if tile.kind == .photo {
                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(tile.time)
                .font(.mono(10, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.trailing, 8)
                .padding(.bottom, 6)
        }
        .overlay(alignment: .bottomLeading) {
            // Первый кадр — это фон тайла, поэтому счётчик показывает лишь СКРЫТЫЙ остаток («+N-1»).
            if tile.photoCount > 1 {
                Text("+\(tile.photoCount - 1)")
                    .font(.mono(10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.leading, 8)
                    .padding(.bottom, 6)
            }
        }
        .overlay { Rectangle().stroke(Color.hairline, lineWidth: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Photo Review Notice («N КП по фото · P баллов»)
// Порт `PhotoReviewNotice`: нотис-предупреждение под метриками, пока есть хоть одно фото-only взятие.
// Объясняет, что фото-часть СУММЫ провизорная — засчитается после проверки судьёй. Заголовок называет
// КП их тайл-токенами; при нулевых баллах (все фото-КП ещё locked) хвост «· P баллов» опускается.
// Warning-палитра (`brandRed`) — те же ставки-под-вопросом, что помечает красный в других нотисах.
private struct PhotoReviewNotice: View {
    let summary: PhotoReviewSummary

    private var title: String {
        let tokens = tokensLabel(summary.tokens)
        if summary.points > 0 {
            // Порт `MarksScreen.kt:921`: склонение «балл/балла/баллов».
            let word = pluralRu(count: summary.points, one: "балл", few: "балла", many: "баллов")
            return "\(summary.count) КП по фото (\(tokens)) · \(summary.points) \(word)"
        }
        return "\(summary.count) КП по фото (\(tokens))"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.brandRed)
                Image(systemName: "camera.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("Баллы засчитают после проверки судьями")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandRed.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
    }
}

// MARK: - Lightbox context
/// Открытый лайтбокс: глобальная лента кадров + стартовый индекс. `Identifiable` для `fullScreenCover(item:)`.
private struct LightboxContext: Identifiable {
    let id = UUID()
    let photos: [LightboxPhoto]
    let initialIndex: Int
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
            case .loading:
                // start() ещё не решил attach-vs-picker — НЕинтерактивная заглушка (зеркалит Android,
                // решающий маршрут до композиции оверлея). Никакого пикера до резолва.
                ZStack {
                    Color.paper.ignoresSafeArea()
                    ProgressView().tint(Color.sub)
                }
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
